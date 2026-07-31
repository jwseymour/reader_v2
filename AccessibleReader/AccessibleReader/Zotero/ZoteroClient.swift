import Foundation

/// Talks to the real Zotero Web API (api.zotero.org). Confirmed this session, live,
/// against this app's target library — annotation items support full CRUD via the
/// standard item write endpoints; the codebase's older assumption ("Zotero has no
/// supported API for writing annotations") was outdated.
struct ZoteroClient {
    var apiKey: String
    static let apiVersion = "3"
    private static let base = "https://api.zotero.org"

    private func authorize(_ request: inout URLRequest) {
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Zotero-API-Version")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    /// `GET /keys/<apikey>` — resolves the numeric userID tied to this API key.
    func resolveUserID() async throws -> Int {
        guard !apiKey.isEmpty else { throw ZoteroError.noAPIKey }
        var request = URLRequest(url: URL(string: "\(Self.base)/keys/\(apiKey)")!)
        authorize(&request)
        let (data, response) = try await send(request)
        try checkStatus(response, data: data)
        let info = try JSONDecoder().decode(ZoteroKeyInfo.self, from: data)
        return info.userID
    }

    /// `GET /users/<id>/items?itemType=annotation&since=<v>` — everything changed
    /// since `since` (0 = full library). Returns the new library version to persist
    /// as the next `since` cursor, read from the `Last-Modified-Version` header.
    func fetchChangedAnnotations(userID: Int, since: Int) async throws -> (items: [ZoteroAnnotationItem], libraryVersion: Int) {
        var components = URLComponents(string: "\(Self.base)/users/\(userID)/items")!
        components.queryItems = [
            URLQueryItem(name: "itemType", value: "annotation"),
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: "100")
        ]
        var request = URLRequest(url: components.url!)
        authorize(&request)
        let (data, response) = try await send(request)
        try checkStatus(response, data: data)
        let items = try JSONDecoder().decode([ZoteroAnnotationItem].self, from: data)
        let version = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Last-Modified-Version")
            .flatMap(Int.init) ?? since
        return (items, version)
    }

    /// `GET /users/<id>/deleted?since=<v>` — the only way to learn about remote
    /// deletions; a deleted item simply vanishes from `fetchChangedAnnotations`, it is
    /// never flagged there.
    func fetchDeletedItemKeys(userID: Int, since: Int) async throws -> [String] {
        var components = URLComponents(string: "\(Self.base)/users/\(userID)/deleted")!
        components.queryItems = [URLQueryItem(name: "since", value: String(since))]
        var request = URLRequest(url: components.url!)
        authorize(&request)
        let (data, response) = try await send(request)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(ZoteroDeletedResponse.self, from: data).items
    }

    /// `GET /users/<id>/items/<key>` — a single item, used to refresh `version` after a 412.
    func fetchAnnotation(userID: Int, key: String) async throws -> ZoteroAnnotationItem {
        var request = URLRequest(url: URL(string: "\(Self.base)/users/\(userID)/items/\(key)")!)
        authorize(&request)
        let (data, response) = try await send(request)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(ZoteroAnnotationItem.self, from: data)
    }

    /// `POST /users/<id>/items` — batch create (server assigns `key`/`version`), up to 50/call.
    func createAnnotations(userID: Int, payloads: [ZoteroAnnotationPayload]) async throws -> ZoteroWriteResponse {
        var request = URLRequest(url: URL(string: "\(Self.base)/users/\(userID)/items")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(payloads)
        let (data, response) = try await send(request)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(ZoteroWriteResponse.self, from: data)
    }

    /// `PATCH /users/<id>/items/<key>` — single-item partial update. Deliberately NOT
    /// the batch POST endpoint: PATCH on the single-item endpoint is the only one that
    /// supports a partial body — sending a full-item POST would overwrite fields this
    /// app never touches (e.g. a tag added directly in Zotero).
    func updateAnnotation(userID: Int, key: String, version: Int, comment: String, color: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "\(Self.base)/users/\(userID)/items/\(key)")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(version), forHTTPHeaderField: "If-Unmodified-Since-Version")
        authorize(&request)
        let body: [String: Any] = ["annotationComment": comment, "annotationColor": color.lowercased()]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        try checkStatus(response, data: data, currentVersionFor: key)
        guard let http = response as? HTTPURLResponse,
              let newVersion = http.value(forHTTPHeaderField: "Last-Modified-Version").flatMap(Int.init) else {
            throw ZoteroError.apiFailed("No version header on update response")
        }
        return newVersion
    }

    /// `DELETE /users/<id>/items/<key>` with `If-Unmodified-Since-Version`.
    func deleteAnnotation(userID: Int, key: String, version: Int) async throws {
        var request = URLRequest(url: URL(string: "\(Self.base)/users/\(userID)/items/\(key)")!)
        request.httpMethod = "DELETE"
        request.setValue(String(version), forHTTPHeaderField: "If-Unmodified-Since-Version")
        authorize(&request)
        let (data, response) = try await send(request)
        try checkStatus(response, data: data, currentVersionFor: key)
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw ZoteroError.offline
        }
    }

    private func checkStatus(_ response: URLResponse, data: Data, currentVersionFor key: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw ZoteroError.apiFailed("No HTTP response") }
        if let retryAfter = http.value(forHTTPHeaderField: "Retry-After") ?? http.value(forHTTPHeaderField: "Backoff"),
           let seconds = TimeInterval(retryAfter) {
            throw ZoteroError.rateLimited(retryAfter: seconds)
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw ZoteroError.unauthorized
        case 412:
            throw ZoteroError.conflict(key: key)
        case 429:
            throw ZoteroError.rateLimited(retryAfter: nil)
        default:
            throw ZoteroError.apiFailed(String(data: data, encoding: .utf8) ?? "Zotero request failed (\(http.statusCode))")
        }
    }
}

enum ZoteroError: LocalizedError {
    case noAPIKey
    case unauthorized
    case conflict(key: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Zotero API key not configured"
        case .unauthorized: return "Zotero rejected the API key"
        case .conflict: return "This annotation changed in Zotero since it was last synced"
        case .rateLimited: return "Zotero rate limit hit — retrying shortly"
        case .offline: return "Couldn't reach Zotero"
        case .apiFailed(let m): return m
        }
    }
}
