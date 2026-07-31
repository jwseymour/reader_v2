import Foundation
import CoreGraphics

/// Wire format for creating a new Zotero `annotation` item, matching the live
/// template returned by `GET /items/new?itemType=annotation&annotationType=highlight`
/// (verified directly against api.zotero.org this session).
///
/// `annotationPosition` is intentionally `String`, not a nested object: the API's
/// own `/items/new` template shows it as a JSON object, but a real `POST` with it
/// encoded that way is rejected with "annotationPosition must be a string" — Zotero
/// expects the position payload double-encoded, as a JSON string containing JSON.
/// This was discovered empirically (Phase 0 spike) and is not documented anywhere;
/// don't "fix" this back to a nested object without re-testing against the real API.
struct ZoteroAnnotationPayload: Encodable {
    var key: String?
    var itemType = "annotation"
    var parentItem: String
    var annotationType = "highlight"
    var annotationText: String
    var annotationComment: String
    var annotationColor: String
    var annotationPageLabel: String
    var annotationSortIndex: String
    var annotationPosition: String
    var tags: [String] = []

    enum CodingKeys: String, CodingKey {
        case key, itemType, parentItem, annotationType, annotationText, annotationComment,
             annotationColor, annotationPageLabel, annotationSortIndex, annotationPosition, tags
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encode(itemType, forKey: .itemType)
        try c.encode(parentItem, forKey: .parentItem)
        try c.encode(annotationType, forKey: .annotationType)
        try c.encode(annotationText, forKey: .annotationText)
        try c.encode(annotationComment, forKey: .annotationComment)
        try c.encode(annotationColor, forKey: .annotationColor)
        try c.encode(annotationPageLabel, forKey: .annotationPageLabel)
        try c.encode(annotationSortIndex, forKey: .annotationSortIndex)
        try c.encode(annotationPosition, forKey: .annotationPosition)
        try c.encode(tags, forKey: .tags)
    }
}

/// A `annotationPosition`-shaped payload, JSON-encoded once, then embedded as a
/// string value inside `ZoteroAnnotationPayload.annotationPosition` (see note above).
private struct ZoteroPosition: Encodable {
    var pageIndex: Int
    var rects: [[Double]]
}

/// Partial view of a Zotero `annotation` item as returned by the API (create/fetch
/// responses) — only the fields this app actually reads back.
struct ZoteroAnnotationItem: Decodable {
    var key: String
    var version: Int
    var data: Data

    struct Data: Decodable {
        var parentItem: String?
        var annotationType: String?
        var annotationText: String?
        var annotationComment: String?
        var annotationColor: String?
        var annotationPageLabel: String?
        var annotationPosition: String?
    }

    /// Decoded `pageIndex`/`rects` out of the double-encoded `annotationPosition` string.
    var position: (pageIndex: Int, rects: [CGRect])? {
        guard let posString = data.annotationPosition,
              let posData = posString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ZoteroDecodedPosition.self, from: posData)
        else { return nil }
        let rects = decoded.rects.compactMap { arr -> CGRect? in
            guard arr.count == 4 else { return nil }
            return CGRect(x: arr[0], y: arr[1], width: arr[2] - arr[0], height: arr[3] - arr[1])
        }
        return (decoded.pageIndex, rects)
    }
}

private struct ZoteroDecodedPosition: Decodable {
    var pageIndex: Int
    var rects: [[Double]]
}

/// Response envelope from the batch write endpoints (`POST`/`PATCH .../items`).
struct ZoteroWriteResponse: Decodable {
    var success: [String: String]
    var successful: [String: ZoteroAnnotationItem]
    var unchanged: [String: String]
    var failed: [String: ZoteroWriteFailure]
}

struct ZoteroWriteFailure: Decodable {
    var code: Int
    var message: String
}

struct ZoteroKeyInfo: Decodable {
    var userID: Int
    var username: String?
}

/// `GET /users/<id>/deleted?since=<v>` — deletions are NOT flagged on regular item
/// fetches; they only ever show up here, as bare keys. Confirmed against the live API
/// this session (deleting a test annotation, then fetching `/deleted`, showed its key
/// here and nowhere else).
struct ZoteroDeletedResponse: Decodable {
    var items: [String]
}

extension PDFHighlightAnnotation {
    /// The one, single place `CGRect` -> Zotero `rects` conversion happens. Confirmed
    /// this session (both by reading Zotero's own open-source `coordinates.js`, which
    /// stores rects via pdf.js's `convertToPdfPoint` into the same bottom-left-origin,
    /// unrotated PDF-user-space PDFKit's `PDFSelection.bounds(for:)` already produces,
    /// AND by an end-to-end test: rendering this exact rect data directly over the
    /// source PDF page landed pixel-precisely on the selected text) — no axis flip or
    /// origin transform needed, direct passthrough.
    ///
    /// Not independently re-verified against a page with a nonzero PDF `/Rotate` value
    /// (none exist in the test library) — both PDFKit and pdf.js claim to normalize
    /// rotation before returning page-space coordinates, but treat this as unverified
    /// if a rotated-page PDF ever surfaces a placement bug.
    var zoteroRects: [[Double]] {
        rects.map { [Double($0.minX), Double($0.minY), Double($0.maxX), Double($0.maxY)] }
    }

    func zoteroCreatePayload(parentItem: String) -> ZoteroAnnotationPayload {
        let position = ZoteroPosition(pageIndex: pageIndex, rects: zoteroRects)
        let positionString = (try? JSONEncoder().encode(position)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // Cosmetic only (Zotero's own annotation-sidebar ordering, never on-page
        // placement) — any value that sorts top-to-bottom within a page is fine, so a
        // fixed constant minus the rect's y works without needing the real page height.
        let yOffset = rects.first.map { max(0, 3000 - $0.maxY) } ?? 0
        let sortIndex = String(format: "%05d|%06d|00000", pageIndex, Int(yOffset))
        return ZoteroAnnotationPayload(
            parentItem: parentItem,
            annotationText: matchText,
            annotationComment: comment,
            annotationColor: color.lowercased(),
            annotationPageLabel: pageLabel ?? String(pageIndex + 1),
            annotationSortIndex: sortIndex,
            annotationPosition: positionString
        )
    }
}
