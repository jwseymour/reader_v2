import SwiftUI
import AppKit

/// Intercepts key events for the whole app *before* AppKit's normal dispatch.
///
/// This exists because SwiftUI's `.commands` menu shortcuts are unreliable the
/// moment a `WKWebView` or `PDFView` has focus (true almost always here, since
/// that's the reading surface): those are AppKit responders that can claim a key
/// combo for themselves before the menu's key-equivalent matching ever runs.
/// `NSEvent.addLocalMonitorForEvents` runs earlier than that — before dispatch —
/// so returning `nil` here reliably consumes the event app-wide regardless of
/// which subview is focused.
struct KeyCaptureView: NSViewRepresentable {
    /// Return `true` if the event was recognized and should be consumed.
    var onEvent: (NSEvent) -> Bool
    /// Reports the hosting window so the caller can tell whether it is the key
    /// window — commands broadcast to every open paper otherwise.
    var onWindow: ((NSWindow?) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.onEvent = onEvent
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyView)?.onEvent = onEvent
        (nsView as? KeyView)?.onWindow = onWindow
    }

    final class KeyView: NSView {
        var onEvent: ((NSEvent) -> Bool)?
        var onWindow: ((NSWindow?) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let hosting = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(hosting) }
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window else { return event }
                // Local monitors are app-wide: ignore keys aimed at any other window,
                // otherwise every open paper reacts to a single keypress.
                guard event.window === window else { return event }
                if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                    return event
                }
                if self.onEvent?(event) == true { return nil }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
