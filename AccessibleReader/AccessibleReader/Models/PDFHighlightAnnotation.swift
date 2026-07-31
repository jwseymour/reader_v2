import Foundation
import PDFKit
import AppKit

/// A user-created highlight + optional comment on a PDF page. Field names
/// deliberately echo Zotero's own annotation schema (`annotationType` /
/// `annotationText` / `annotationComment` / `annotationColor` /
/// `annotationPageLabel`) — as of the live Zotero Web API sync (`ZoteroSyncStore`),
/// this is no longer just a naming convention: these fields map directly onto a
/// real Zotero `annotation` item. The one-way "Export Highlights to PDF" bridge in
/// `ReaderWindowView` still exists as a fallback for documents not linked to Zotero.
struct PDFHighlightAnnotation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// `fileURL.standardizedFileURL.path` — a plain string so
    /// `annotations.json` stays human-inspectable. Renaming/moving the source
    /// file orphans its highlights; not solved in v1.
    var documentKey: String
    var pageIndex: Int
    /// The exact selected text. Kept for display (the Reading Lab's highlight
    /// list) — geometry is *not* re-derived from this at render time (see
    /// `rects` below); an earlier version tried relocating text via
    /// `PDFDocument.findString` on every render, which does not reliably
    /// round-trip a selection that wraps across lines, so the highlight
    /// rectangle and the popover anchored to it would land in the wrong
    /// place. PDF page geometry never changes for a given file, so capturing
    /// exact rects once at creation time is both simpler and correct.
    var matchText: String
    var comment: String
    /// Hex color, e.g. "#FFD400".
    var color: String
    /// Page-space rects (one per line the original selection spanned),
    /// captured directly from `PDFSelection` at creation time. Confirmed
    /// (session verification, see ZoteroClient) to use the same bottom-left-origin,
    /// unrotated PDF-user-space convention as Zotero's own `annotationPosition.rects`
    /// — no coordinate transform is needed when pushing to the Zotero API.
    var rects: [CGRect]
    var dateAdded: Date = Date()

    // MARK: - Zotero linkage (nil = never synced)

    /// This annotation's own Zotero item key, once created remotely.
    var zoteroItemKey: String? = nil
    /// Zotero item `version` last seen from the server — sent as
    /// `If-Unmodified-Since-Version` on update/delete for optimistic concurrency.
    var zoteroVersion: Int? = nil
    /// `PDFPage.label` at creation time (e.g. "iv", "12") — Zotero's `annotationPageLabel`.
    var pageLabel: String? = nil
}

struct HighlightSwatch: Identifiable {
    let id = UUID()
    let name: String
    let hex: String
}

/// Fixed palette matching Zotero's own default highlight colors, so a
/// highlight's color reads the same after an eventual round trip through
/// Zotero's Import Annotations.
enum HighlightSwatches {
    static let all: [HighlightSwatch] = [
        .init(name: "Yellow", hex: "#FFD400"),
        .init(name: "Green", hex: "#5FB236"),
        .init(name: "Blue", hex: "#2EA8E5"),
        .init(name: "Red", hex: "#FF6666")
    ]
    static let defaultHex = "#FFD400"
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let a, r, g, b: CGFloat
        if s.count == 8 {
            a = CGFloat((value & 0xFF000000) >> 24) / 255
            r = CGFloat((value & 0x00FF0000) >> 16) / 255
            g = CGFloat((value & 0x0000FF00) >> 8) / 255
            b = CGFloat(value & 0x000000FF) / 255
        } else {
            a = 1
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Locates stored highlight records inside a live `PDFDocument` and turns
/// them into real embedded PDF annotation objects. This is the single code
/// path used both for on-screen rendering (`PDFVisualView`) and for the
/// "Export Highlights to PDF" write, so a highlight is only ever placed one
/// way.
enum PDFHighlightRendering {
    /// Tags every annotation this app creates, so a rebuild can tell its own
    /// highlights apart from any pre-existing third-party ones in the file
    /// and never touch those.
    static let annotationKey = PDFAnnotationKey(rawValue: "ARHighlightID")

    /// One page-space rect per line `selection` spans on `page` — a plain
    /// single bounding box on a multi-line selection would visually block the
    /// line-wrap gaps.
    static func rects(for selection: PDFSelection, on page: PDFPage) -> [CGRect] {
        let lines = selection.selectionsByLine()
        return (lines.isEmpty ? [selection] : lines).compactMap { line -> CGRect? in
            guard line.pages.contains(page) else { return nil }
            let rect = line.bounds(for: page)
            return (rect.isNull || rect.isEmpty) ? nil : rect
        }
    }

    /// Builds the actual `PDFAnnotation` for `record` at `rects` (its own
    /// stored geometry). Not attached to a page — the caller does that.
    static func buildAnnotation(for record: PDFHighlightAnnotation, rects: [CGRect]) -> PDFAnnotation {
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let annotation = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
        annotation.color = NSColor(hex: record.color) ?? .yellow
        var quads: [NSValue] = []
        // `quadrilateralPoints` is documented (PDFAnnotationUtilities.h) as
        // "specified relative to the annotation's bounds origin" — passing
        // absolute page-space coordinates here (as this used to) makes
        // PDFKit apply the bounds offset a second time when drawing, so the
        // highlight lands nowhere near the selected text (or off-page
        // entirely, rendering as nothing at all).
        let ox = union.minX, oy = union.minY
        for rect in rects {
            // Empirically, PDFKit expects each quad's four points in
            // top-left, top-right, bottom-left, bottom-right order — not the
            // raw PDF-spec winding order. A skewed/crossed rectangle in
            // Preview.app means this needs flipping.
            quads.append(NSValue(point: CGPoint(x: rect.minX - ox, y: rect.maxY - oy)))
            quads.append(NSValue(point: CGPoint(x: rect.maxX - ox, y: rect.maxY - oy)))
            quads.append(NSValue(point: CGPoint(x: rect.minX - ox, y: rect.minY - oy)))
            quads.append(NSValue(point: CGPoint(x: rect.maxX - ox, y: rect.minY - oy)))
        }
        annotation.quadrilateralPoints = quads
        annotation.contents = record.comment.isEmpty ? nil : record.comment
        annotation.setValue(record.id.uuidString, forAnnotationKey: annotationKey)
        return annotation
    }

    /// Removes only annotations this app previously added (tagged with
    /// `annotationKey`), leaving any pre-existing third-party annotations
    /// untouched. Call before every rebuild — live refresh or export — so
    /// re-rendering never stacks duplicate rectangles.
    static func removeManagedAnnotations(from document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for annotation in page.annotations where annotation.value(forAnnotationKey: annotationKey) != nil {
                page.removeAnnotation(annotation)
            }
        }
    }

    /// Rebuilds every stored highlight for this document onto `document`,
    /// clearing this app's previous annotations first so repeated calls never
    /// duplicate rectangles. Uses each record's own stored `rects` directly —
    /// PDF page geometry is fixed, so the page at `record.pageIndex` in any
    /// load of this same file has identical coordinates. Returns the number
    /// of records that couldn't be placed (e.g. the page no longer exists).
    @discardableResult
    static func apply(_ records: [PDFHighlightAnnotation], to document: PDFDocument) -> Int {
        removeManagedAnnotations(from: document)
        var unplaced = 0
        for record in records {
            guard let page = document.page(at: record.pageIndex), !record.rects.isEmpty else {
                unplaced += 1
                continue
            }
            page.addAnnotation(buildAnnotation(for: record, rects: record.rects))
        }
        return unplaced
    }

    /// This app's own annotation at `point` (page space) on `page`, if any.
    /// Tests against the actual per-line quads, not just `annotation.bounds`
    /// — for a highlight spanning lines of very different widths, the union
    /// bounding box covers empty space the eye doesn't read as highlighted,
    /// which made clicks well away from any actual highlighted text register
    /// as a hit.
    static func managedAnnotation(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { annotation in
            guard annotation.value(forAnnotationKey: annotationKey) != nil else { return false }
            guard let quads = annotation.quadrilateralPoints, !quads.isEmpty else {
                return annotation.bounds.contains(point)
            }
            // Quad points are relative to the annotation's bounds origin
            // (same convention `buildAnnotation` writes them in) — shift back
            // to page space before comparing against `point`.
            let origin = annotation.bounds.origin
            let points = quads.map { CGPoint(x: $0.pointValue.x + origin.x, y: $0.pointValue.y + origin.y) }
            var index = 0
            while index + 3 < points.count {
                let tl = points[index], tr = points[index + 1], bl = points[index + 2], br = points[index + 3]
                let rect = CGRect(
                    x: min(tl.x, bl.x), y: min(bl.y, br.y),
                    width: max(tr.x, br.x) - min(tl.x, bl.x), height: max(tl.y, tr.y) - min(bl.y, br.y)
                )
                if rect.contains(point) { return true }
                index += 4
            }
            return false
        }
    }

    static func recordID(for annotation: PDFAnnotation) -> UUID? {
        (annotation.value(forAnnotationKey: annotationKey) as? String).flatMap { UUID(uuidString: $0) }
    }
}
