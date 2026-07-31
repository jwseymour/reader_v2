import Foundation

/// Persists `PDFHighlightAnnotation` records — the durable source of truth
/// for highlights, independent of what's embedded in any PDF file at a given
/// moment (Zotero strips embedded copies back out once imported, so the file
/// itself can never be relied on to still hold them). Follows `PresetStore`'s
/// pattern: one JSON array under Application Support, loaded once at launch.
@MainActor
final class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()

    @Published private(set) var all: [PDFHighlightAnnotation] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AccessibleReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("annotations.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PDFHighlightAnnotation].self, from: data) else {
            all = []
            return
        }
        all = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func list(for documentKey: String) -> [PDFHighlightAnnotation] {
        all.filter { $0.documentKey == documentKey }
            .sorted { ($0.pageIndex, $0.dateAdded) < ($1.pageIndex, $1.dateAdded) }
    }

    func add(_ annotation: PDFHighlightAnnotation) {
        all.append(annotation)
        save()
    }

    func update(_ annotation: PDFHighlightAnnotation) {
        guard let idx = all.firstIndex(where: { $0.id == annotation.id }) else { return }
        all[idx] = annotation
        save()
    }

    func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }
}
