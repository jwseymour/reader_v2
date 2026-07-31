import Foundation

/// Maps a local document (by `documentKey`, matching `PDFHighlightAnnotation.documentKey`)
/// to the Zotero attachment item that represents the same PDF. Kept separate from
/// `PDFHighlightAnnotation` because this is a per-document fact, not per-highlight.
struct ZoteroDocumentLink: Codable, Equatable {
    var documentKey: String
    var libraryID: Int
    var libraryType: String = "user" // v1: personal library only
    var attachmentItemKey: String
    var resolvedVia: String // "storagePath" | "manual"
}

/// Persists `ZoteroDocumentLink` records — same singleton + JSON-under-Application-Support
/// convention as `AnnotationStore`/`PresetStore`.
@MainActor
final class ZoteroLinkStore: ObservableObject {
    static let shared = ZoteroLinkStore()

    @Published private(set) var links: [ZoteroDocumentLink] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AccessibleReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("zotero_links.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ZoteroDocumentLink].self, from: data) else {
            links = []
            return
        }
        links = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func link(for documentKey: String) -> ZoteroDocumentLink? {
        links.first { $0.documentKey == documentKey }
    }

    /// Reverse lookup — used when a remotely-discovered annotation (created directly
    /// in Zotero) needs to be mapped back to a local `documentKey`.
    func link(forAttachmentItemKey key: String) -> ZoteroDocumentLink? {
        links.first { $0.attachmentItemKey == key }
    }

    func setLink(_ link: ZoteroDocumentLink) {
        if let idx = links.firstIndex(where: { $0.documentKey == link.documentKey }) {
            links[idx] = link
        } else {
            links.append(link)
        }
        save()
    }

    func removeLink(for documentKey: String) {
        links.removeAll { $0.documentKey == documentKey }
        save()
    }
}
