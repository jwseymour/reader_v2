import Foundation

/// Wraps Zotero's Streaming API (`wss://stream.zotero.org`) so `ZoteroSyncStore` learns
/// about remote library changes (e.g. a highlight edited directly in Zotero) within
/// moments, instead of only on the next document open. The socket only ever signals
/// "something changed at version N" — it never carries the changed data itself, so
/// every event still routes through the normal incremental `ZoteroSyncStore.reconcileLibrary()`.
///
/// Message shapes below are confirmed live against the real API this session (not just
/// the docs, which only describe the mechanism in prose):
///   recv  {"event":"connected","retry":10000}
///   send  {"action":"createSubscriptions","subscriptions":[{"apiKey":"..."}]}
///   recv  {"event":"subscriptionsCreated","subscriptions":[...],"errors":[]}
///   recv  {"event":"topicUpdated","topic":"/users/<id>","version":<v>}
@MainActor
final class ZoteroStreamingClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var apiKey: String = ""
    var onTopicUpdated: (() -> Void)?

    func connect(apiKey: String) {
        disconnect()
        self.apiKey = apiKey
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: URL(string: "wss://stream.zotero.org")!)
        self.task = task
        task.resume()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
    }

    private func subscribe() {
        guard let task, !apiKey.isEmpty else { return }
        let body: [String: Any] = ["action": "createSubscriptions", "subscriptions": [["apiKey": apiKey]]]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { _ in }
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receiveLoop()
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    self.receiveLoop()
                case .success:
                    self.receiveLoop()
                case .failure:
                    // Connection dropped — a fresh `resolveLink`/reconcile on next document
                    // open still catches anything missed; no reconnect-with-backoff loop for v1.
                    self.task = nil
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else { return }
        switch event {
        case "connected":
            subscribe()
        case "topicUpdated":
            onTopicUpdated?()
        default:
            break
        }
    }
}

extension ZoteroStreamingClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in self?.task = nil }
    }
}
