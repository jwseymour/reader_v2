import Foundation
import PDFKit
import AppKit
import CoreGraphics

// MARK: - Content stream scanning

/// One text-showing operation from the page content stream.
struct GlyphRun {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let glyphs: Int
    let fontName: String
}

/// Mutable scanner state. Passed to the C callbacks through their `info` pointer,
/// which is the only channel available — they cannot capture context.
/// Glyph advance widths for one font, in 1/1000 em.
private struct PDFFontMetrics {
    var firstChar = 0
    var widths: [CGFloat] = []
    var missingWidth: CGFloat = 500
    var twoByte = false

    func width(forCode code: Int) -> CGFloat {
        let index = code - firstChar
        guard index >= 0, index < widths.count else { return missingWidth }
        let w = widths[index]
        return w > 0 ? w : missingWidth
    }
}

private final class PDFScanState {
    var runs: [GlyphRun] = []
    var stream: CGPDFContentStreamRef?
    var fontName = ""
    var fontSize: CGFloat = 0
    var metrics = PDFFontMetrics()
    var metricsCache: [String: PDFFontMetrics] = [:]
    var charSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    var leading: CGFloat = 0
    var ctm = CGAffineTransform.identity
    var ctmStack: [CGAffineTransform] = []

    /// Exact advance for a shown string, so the x of the *next* run is right.
    /// Style boundaries are located by x, so a guessed advance shows up as bold or
    /// italic bleeding a few characters past where it belongs.
    func advance(forBytes bytes: UnsafePointer<UInt8>, length: Int) -> CGFloat {
        var total: CGFloat = 0
        let step = metrics.twoByte ? 2 : 1
        var i = 0
        while i + step <= length {
            let code = step == 2
                ? Int(bytes[i]) << 8 | Int(bytes[i + 1])
                : Int(bytes[i])
            total += metrics.width(forCode: code) / 1000 * fontSize + charSpacing
            if step == 1 && code == 32 { total += wordSpacing }
            i += step
        }
        return total * horizontalScale
    }

    func show(glyphs: Int, advance: CGFloat) {
        if glyphs > 0 {
            let combined = textMatrix.concatenating(ctm)
            let scale = sqrt(abs(combined.a * combined.d - combined.b * combined.c))
            let size = fontSize * (scale > 0 ? scale : 1)
            // Merge with the previous run when the style has not changed: fewer
            // boundaries means fewer places an inaccuracy can show up.
            if var last = runs.last,
               last.fontName == fontName,
               abs(last.y - combined.ty) < 0.5,
               abs(last.size - size) < 0.15 {
                last = GlyphRun(x: last.x, y: last.y, size: last.size,
                                glyphs: last.glyphs + glyphs, fontName: last.fontName)
                runs[runs.count - 1] = last
            } else {
                runs.append(GlyphRun(x: combined.tx, y: combined.ty, size: size,
                                     glyphs: glyphs, fontName: fontName))
            }
        }
        textMatrix = textMatrix.translatedBy(x: advance, y: 0)
    }

    func newLine(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = lineMatrix.translatedBy(x: tx, y: ty)
        textMatrix = lineMatrix
    }
}

private func pdfState(_ info: UnsafeMutableRawPointer?) -> PDFScanState? {
    guard let info else { return nil }
    return Unmanaged<PDFScanState>.fromOpaque(info).takeUnretainedValue()
}

private func pdfNumber(_ scanner: CGPDFScannerRef) -> CGFloat {
    var value: CGPDFReal = 0
    return CGPDFScannerPopNumber(scanner, &value) ? CGFloat(value) : 0
}

private func pdfShow(_ state: PDFScanState, _ string: CGPDFStringRef) {
    let length = CGPDFStringGetLength(string)
    guard length > 0, let bytes = CGPDFStringGetBytePtr(string) else { return }
    let glyphs = state.metrics.twoByte ? length / 2 : length
    let advance = state.advance(forBytes: bytes, length: length)
    state.show(glyphs: glyphs, advance: advance)
}

private func pdfFontDictionary(named name: String, in stream: CGPDFContentStreamRef?) -> CGPDFDictionaryRef? {
    guard let stream,
          let object = CGPDFContentStreamGetResource(stream, "Font", name) else { return nil }
    var dict: CGPDFDictionaryRef?
    guard CGPDFObjectGetValue(object, .dictionary, &dict) else { return nil }
    return dict
}

private func pdfBaseFont(in dict: CGPDFDictionaryRef?) -> String? {
    guard let dict else { return nil }
    var base: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(dict, "BaseFont", &base), let base else { return nil }
    return String(cString: base)
}

private func pdfMetrics(in dict: CGPDFDictionaryRef?) -> PDFFontMetrics {
    var metrics = PDFFontMetrics()
    guard let dict else { return metrics }

    var subtype: UnsafePointer<Int8>?
    if CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype {
        // Composite fonts address glyphs with two-byte codes.
        metrics.twoByte = String(cString: subtype) == "Type0"
    }

    var firstChar: CGPDFInteger = 0
    if CGPDFDictionaryGetInteger(dict, "FirstChar", &firstChar) {
        metrics.firstChar = Int(firstChar)
    }

    var widths: CGPDFArrayRef?
    if CGPDFDictionaryGetArray(dict, "Widths", &widths), let widths {
        let count = CGPDFArrayGetCount(widths)
        metrics.widths.reserveCapacity(count)
        for i in 0..<count {
            var value: CGPDFReal = 0
            metrics.widths.append(CGPDFArrayGetNumber(widths, i, &value) ? CGFloat(value) : 0)
        }
    }

    var descriptor: CGPDFDictionaryRef?
    if CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &descriptor), let descriptor {
        var missing: CGPDFReal = 0
        if CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing), missing > 0 {
            metrics.missingWidth = CGFloat(missing)
        }
    }
    // Composite fonts keep widths in /W; 1000 is the usual default for full-width glyphs.
    if metrics.twoByte && metrics.widths.isEmpty {
        metrics.missingWidth = 1000
    }
    return metrics
}

/// Reads real font names and positions straight from the PDF content stream.
///
/// This exists because `PDFSelection.attributedString` substitutes a generic face
/// (typically Helvetica) for embedded fonts and drops the symbolic traits, so bold
/// and italic are simply not recoverable from PDFKit's own attributed string.
enum PDFContentScanner {

    static func runs(for page: PDFPage) -> [GlyphRun] {
        guard let ref = page.pageRef else { return [] }
        let state = PDFScanState()
        let stream = CGPDFContentStreamCreateWithPage(ref)
        state.stream = stream
        guard let table = operatorTable() else {
            CGPDFContentStreamRelease(stream)
            return []
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return state.runs
    }

    private static func operatorTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }

        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let st = pdfState(info) else { return }
            st.fontSize = pdfNumber(scanner)
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let resourceName = String(cString: name)
            let dict = pdfFontDictionary(named: resourceName, in: st.stream)
            st.fontName = pdfBaseFont(in: dict) ?? resourceName
            if let cached = st.metricsCache[resourceName] {
                st.metrics = cached
            } else {
                let metrics = pdfMetrics(in: dict)
                st.metricsCache[resourceName] = metrics
                st.metrics = metrics
            }
        }

        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
            guard let st = pdfState(info) else { return }
            st.charSpacing = pdfNumber(scanner)
        }

        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
            guard let st = pdfState(info) else { return }
            st.wordSpacing = pdfNumber(scanner)
        }

        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            guard let st = pdfState(info) else { return }
            let value = pdfNumber(scanner)
            st.horizontalScale = value > 0 ? value / 100 : 1
        }

        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let st = pdfState(info) else { return }
            let f = pdfNumber(scanner), e = pdfNumber(scanner), d = pdfNumber(scanner)
            let c = pdfNumber(scanner), b = pdfNumber(scanner), a = pdfNumber(scanner)
            st.lineMatrix = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
            st.textMatrix = st.lineMatrix
        }

        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let st = pdfState(info) else { return }
            st.textMatrix = .identity
            st.lineMatrix = .identity
        }

        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let st = pdfState(info) else { return }
            let ty = pdfNumber(scanner), tx = pdfNumber(scanner)
            st.newLine(tx, ty)
        }

        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let st = pdfState(info) else { return }
            let ty = pdfNumber(scanner), tx = pdfNumber(scanner)
            st.leading = -ty
            st.newLine(tx, ty)
        }

        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let st = pdfState(info) else { return }
            st.leading = pdfNumber(scanner)
        }

        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let st = pdfState(info) else { return }
            st.newLine(0, -st.leading)
        }

        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let st = pdfState(info) else { return }
            let f = pdfNumber(scanner), e = pdfNumber(scanner), d = pdfNumber(scanner)
            let c = pdfNumber(scanner), b = pdfNumber(scanner), a = pdfNumber(scanner)
            st.ctm = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f).concatenating(st.ctm)
        }

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let st = pdfState(info) else { return }
            st.ctmStack.append(st.ctm)
        }

        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let st = pdfState(info) else { return }
            if let last = st.ctmStack.popLast() { st.ctm = last }
        }

        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let st = pdfState(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            pdfShow(st, string)
        }

        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let st = pdfState(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            st.newLine(0, -st.leading)
            pdfShow(st, string)
        }

        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let st = pdfState(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for i in 0..<CGPDFArrayGetCount(array) {
                var object: CGPDFObjectRef?
                guard CGPDFArrayGetObject(array, i, &object), let object else { continue }
                var string: CGPDFStringRef?
                if CGPDFObjectGetValue(object, .string, &string), let string {
                    pdfShow(st, string)
                    continue
                }
                // Numbers in a TJ array are kerning offsets in 1/1000 em.
                var adjust: CGPDFReal = 0
                if CGPDFObjectGetValue(object, .real, &adjust) || CGPDFObjectGetValue(object, .integer, &adjust) {
                    let shift = -CGFloat(adjust) / 1000 * st.fontSize * st.horizontalScale
                    st.show(glyphs: 0, advance: shift)
                }
            }
        }

        return table
    }
}

// MARK: - Font style classification

/// Decides bold/italic from real PostScript names.
///
/// Keyword matching handles conventional names (`Times-Bold`, `CMTI10`). Everything
/// else is resolved by looking for a shorter font name on the same page that is a
/// prefix of this one — `LinLibertineT` vs `LinLibertineTB` — and reading the
/// one or two character suffix, which is how most families encode their variants.
struct FontStyleTable {
    private var bold: Set<String> = []
    private var italic: Set<String> = []

    init(runs: [GlyphRun]) {
        var weights: [String: Int] = [:]
        for run in runs where !run.fontName.isEmpty {
            weights[Self.normalize(run.fontName), default: 0] += run.glyphs
        }
        let names = Set(weights.keys)

        for name in names {
            var isBold = Self.boldKeywords.contains { name.contains($0) }
            var isItalic = Self.italicKeywords.contains { name.contains($0) }

            if !isBold && !isItalic, let suffix = Self.variantSuffix(of: name, among: names) {
                isBold = suffix.contains("b")
                isItalic = suffix.contains("i") || suffix.contains("o")
            }
            if isBold { bold.insert(name) }
            if isItalic { italic.insert(name) }
        }
    }

    func isBold(_ fontName: String) -> Bool { bold.contains(Self.normalize(fontName)) }
    func isItalic(_ fontName: String) -> Bool { italic.contains(Self.normalize(fontName)) }

    /// Drops the six-letter subset prefix PDF writers prepend, e.g. `EZQGUZ+`.
    private static func normalize(_ name: String) -> String {
        var value = name
        if let plus = value.firstIndex(of: "+"), value.distance(from: value.startIndex, to: plus) <= 7 {
            value = String(value[value.index(after: plus)...])
        }
        return value.lowercased()
    }

    private static let boldKeywords = ["bold", "black", "heavy", "semib", "demib", "-bd", "cmbx", "-medi"]
    private static let italicKeywords = ["italic", "oblique", "kursiv", "cmti", "cmmi", "-it"]

    private static func variantSuffix(of name: String, among names: Set<String>) -> String? {
        for candidate in names where candidate != name && name.hasPrefix(candidate) {
            let suffix = String(name.dropFirst(candidate.count))
            if !suffix.isEmpty && suffix.count <= 2 { return suffix }
        }
        return nil
    }
}

struct ExtractedPage: Identifiable, Hashable {
    let id: Int
    let pageIndex: Int
    /// Plain text for search / TTS.
    let text: String
    /// Structured HTML preserving headings, bold, italic, underline, and indents.
    let html: String
}

enum PDFExtractor {
    static func extractPages(from data: Data) -> [ExtractedPage] {
        guard let doc = PDFDocument(data: data) else { return [] }
        var pages: [ExtractedPage] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let structured = structure(page: page)
            pages.append(ExtractedPage(
                id: i,
                pageIndex: i,
                text: structured.plain,
                html: structured.html
            ))
        }
        return pages
    }

    static func extractionLooksViable(_ pages: [ExtractedPage]) -> Bool {
        let total = pages.reduce(0) { $0 + $1.text.count }
        return total > 80
    }

    // MARK: - Line model (keeps full attributed text for inline runs)

    private struct Line {
        var text: NSAttributedString
        var fontSize: CGFloat
        /// Absolute x in page space when available, resolved to a column-relative
        /// indent once every line on the page is known.
        var indent: CGFloat
        var isBold: Bool
        var isBlank: Bool { text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var plain: String { text.string }
    }

    /// Horizontal position of a character in page space, used for real indent detection.
    static let xPositionKey = NSAttributedString.Key("readerX")

    private static func structure(page: PDFPage) -> (plain: String, html: String) {
        if let attr = styledAttributedString(for: page), attr.length > 0 {
            return html(from: attr)
        }
        if let attr = attributedString(for: page), attr.length > 0 {
            return html(from: attr)
        }
        let raw = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (raw, plainFallbackHTML(raw))
    }

    /// Text from PDFKit (which orders columns correctly *within* a column) with
    /// styling recovered from the content stream and stitched back on by
    /// position. Reading order across columns is re-derived ourselves — see
    /// `readingOrder(for:bounds:length:)` — since PDFKit's own column-order
    /// heuristic can jump to the next column early, typically right after a
    /// heading or bulleted list, silently reading the rest of the current
    /// column out of place.
    private static func styledAttributedString(for page: PDFPage) -> NSAttributedString? {
        guard let text = page.string, !text.isEmpty else { return nil }
        let runs = PDFContentScanner.runs(for: page).filter { !$0.fontName.isEmpty }
        guard runs.count > 1 else { return nil }

        let styles = FontStyleTable(runs: runs)

        // Bucket runs by baseline so a character only compares against its own line.
        var byLine: [Int: [GlyphRun]] = [:]
        for run in runs {
            byLine[Int(run.y.rounded()), default: []].append(run)
        }
        for key in byLine.keys {
            byLine[key]?.sort { $0.x < $1.x }
        }
        let lineKeys = byLine.keys.sorted()

        let ns = text as NSString
        let allBounds = (0..<ns.length).map { page.characterBounds(at: $0) }
        let order = readingOrder(for: page, bounds: allBounds, length: ns.length)

        let result = NSMutableAttributedString()
        var pending = ""
        var pendingAttrs: [NSAttributedString.Key: Any]?

        func flush() {
            guard !pending.isEmpty else { return }
            result.append(NSAttributedString(string: pending, attributes: pendingAttrs ?? [:]))
            pending = ""
        }

        for i in order {
            let character = ns.substring(with: NSRange(location: i, length: 1))
            let bounds = allBounds[i]

            // Whitespace and line breaks have no useful bounds — keep the run going.
            let isBlank = character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank || bounds.isEmpty || bounds.height <= 0 {
                pending += character
                continue
            }

            guard let run = nearestRun(to: bounds, byLine: byLine, lineKeys: lineKeys) else {
                pending += character
                continue
            }

            let attrs = attributes(for: run, x: bounds.minX, styles: styles)
            if pendingAttrs == nil {
                pendingAttrs = attrs
            } else if !sameStyle(pendingAttrs!, attrs) {
                flush()
                pendingAttrs = attrs
            }
            pending += character
        }
        flush()
        return result
    }

    /// Re-sequences character indices `0..<length` as "all of column 0 in
    /// original relative order, then all of column 1 in original relative
    /// order" when a two-column gutter is detected, otherwise returns them
    /// unchanged. Whitespace/line-break characters (no usable bounds) inherit
    /// whichever column the last real character before them landed in, so
    /// paragraph breaks stay attached to the right side.
    ///
    /// This works because PDFKit's own order is only wrong *across* columns —
    /// within one column it already reads top-to-bottom correctly — so a
    /// stable partition by column reconstructs proper reading order without
    /// needing to re-derive line/column geometry from scratch.
    private static func readingOrder(for page: PDFPage, bounds allBounds: [CGRect], length: Int) -> [Int] {
        guard let gutter = columnGutter(for: page, bounds: allBounds) else {
            return Array(0..<length)
        }
        var column0: [Int] = []
        var column1: [Int] = []
        column0.reserveCapacity(length)
        var lastColumn = 0
        for i in 0..<length {
            let b = allBounds[i]
            let column: Int
            if b.isEmpty || b.height <= 0 {
                column = lastColumn
            } else {
                column = b.minX < gutter ? 0 : 1
                lastColumn = column
            }
            if column == 0 { column0.append(i) } else { column1.append(i) }
        }
        return column0 + column1
    }

    /// Detects a single vertical gutter separating two text columns from the
    /// x-positions of every character with usable bounds: a wide, nearly-empty
    /// band roughly in the middle of the page, with a substantial share of
    /// characters on each side (so an image or a page that's merely sparse
    /// isn't mistaken for a column break). Returns nil — treat as a single
    /// column, the common case — when none of this holds.
    private static func columnGutter(for page: PDFPage, bounds allBounds: [CGRect]) -> CGFloat? {
        let pageWidth = page.bounds(for: .mediaBox).width
        guard pageWidth > 100 else { return nil }

        let xs = allBounds.filter { !$0.isEmpty && $0.height > 0 }.map(\.minX)
        // Below this, a page is sparse enough (title page furniture, a
        // caption-only appendix page) that a "gutter" is more likely noise
        // than a real column break.
        guard xs.count >= 600 else { return nil }

        let bucketWidth: CGFloat = max(6, pageWidth / 40)
        let bucketCount = Int((pageWidth / bucketWidth).rounded(.up)) + 1
        var counts = [Int](repeating: 0, count: bucketCount)
        for x in xs {
            let k = Int((x / bucketWidth).rounded(.down))
            if counts.indices.contains(k) { counts[k] += 1 }
        }

        // Margins and figure edges shouldn't be mistaken for a column break —
        // only look for a gutter roughly in the middle of the page.
        let loBound = Int((pageWidth * 0.2) / bucketWidth)
        let hiBound = Int((pageWidth * 0.8) / bucketWidth)
        guard loBound < hiBound, hiBound < counts.count else { return nil }
        let central = counts[loBound...hiBound]

        let sortedCentral = central.sorted()
        let median = CGFloat(sortedCentral[sortedCentral.count / 2])
        guard median > 0 else { return nil }
        let quietThreshold = median * 0.45

        // Widest run of quiet buckets within the central band.
        var bestStart = -1, bestLen = 0
        var runStart = -1
        for k in loBound...hiBound {
            if CGFloat(counts[k]) <= quietThreshold {
                if runStart < 0 { runStart = k }
            } else {
                if runStart >= 0 {
                    let len = k - runStart
                    if len > bestLen { bestLen = len; bestStart = runStart }
                    runStart = -1
                }
            }
        }
        if runStart >= 0 {
            let len = hiBound + 1 - runStart
            if len > bestLen { bestLen = len; bestStart = runStart }
        }
        guard bestStart >= 0 else { return nil }

        let gutterMinX = CGFloat(bestStart) * bucketWidth
        let gutterMaxX = CGFloat(bestStart + bestLen) * bucketWidth
        guard gutterMaxX - gutterMinX >= 8 else { return nil }
        let gutter = (gutterMinX + gutterMaxX) / 2

        let leftCount = xs.filter { $0 < gutterMinX }.count
        let rightCount = xs.filter { $0 > gutterMaxX }.count
        let minSide = Int(Double(xs.count) * 0.15)
        guard leftCount >= minSide, rightCount >= minSide else { return nil }

        // The bug this exists to fix has a distinctive signature: PDFKit reads
        // a column correctly, jumps to the other column once (typically at a
        // heading or list), and maybe jumps back once for a tail — a handful
        // of switches in the *original* order. A title-page byline block or
        // other grid-like layout, where content legitimately alternates sides
        // many times, looks completely different: dozens of switches. Only
        // reorder when the low-switch signature actually holds, so a page
        // that isn't really two stacked full-height columns is left alone
        // rather than shuffled into something worse.
        var lastColumn = -1
        var switches = 0
        for b in allBounds {
            guard !b.isEmpty, b.height > 0 else { continue }
            let column = b.minX < gutter ? 0 : 1
            if lastColumn != -1, column != lastColumn { switches += 1 }
            lastColumn = column
        }
        guard switches <= 8 else { return nil }

        return gutter
    }

    private static func nearestRun(
        to bounds: CGRect,
        byLine: [Int: [GlyphRun]],
        lineKeys: [Int]
    ) -> GlyphRun? {
        // A glyph's box sits a little below its baseline; search a band around it.
        let baseline = bounds.minY + bounds.height * 0.22
        let tolerance = max(3.0, bounds.height * 0.9)
        var best: GlyphRun?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for key in lineKeys {
            let delta = abs(CGFloat(key) - baseline)
            if delta > tolerance { continue }
            guard let line = byLine[key] else { continue }
            // Within a line, the run governing this character is the last one
            // starting at or before it.
            var candidate = line.first
            for run in line where run.x <= bounds.minX + 1.5 { candidate = run }
            guard let candidate else { continue }
            if delta < bestScore {
                bestScore = delta
                best = candidate
            }
        }
        return best
    }

    private static func attributes(
        for run: GlyphRun,
        x: CGFloat,
        styles: FontStyleTable
    ) -> [NSAttributedString.Key: Any] {
        let size = run.size > 0.5 ? run.size : 12
        var traits: NSFontDescriptor.SymbolicTraits = []
        if styles.isBold(run.fontName) { traits.insert(.bold) }
        if styles.isItalic(run.fontName) { traits.insert(.italic) }

        let base = NSFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        return [.font: font, xPositionKey: x]
    }

    private static func sameStyle(
        _ a: [NSAttributedString.Key: Any],
        _ b: [NSAttributedString.Key: Any]
    ) -> Bool {
        guard let fa = a[.font] as? NSFont, let fb = b[.font] as? NSFont else { return false }
        return fa.fontName == fb.fontName && abs(fa.pointSize - fb.pointSize) < 0.2
    }

    private static func attributedString(for page: PDFPage) -> NSAttributedString? {
        let bounds = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: bounds) else { return nil }
        return selection.attributedString
    }

    private static func html(from attr: NSAttributedString) -> (plain: String, html: String) {
        let lines = lines(from: attr)
        guard !lines.isEmpty else {
            let raw = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw, plainFallbackHTML(raw))
        }

        let bodySizes = lines.map(\.fontSize).filter { $0 > 0 }
        let median = medianSize(bodySizes) ?? 12
        let headingThreshold = median * 1.18
        let edges = columnEdges(from: lines.filter { !$0.isBlank }.map(\.indent))
        let indentStep = max(12, median * 0.9)

        var paragraphs: [NSAttributedString] = []
        var indentLevels: [Int] = []
        var current: NSMutableAttributedString?
        var currentIndent = 0
        var currentBold = false

        func flush() {
            guard let cur = current, cur.length > 0 else {
                current = nil
                return
            }
            paragraphs.append(cur)
            indentLevels.append(currentIndent)
            current = nil
        }

        for line in lines {
            if line.isBlank {
                flush()
                continue
            }

            let relative = relativeIndent(line.indent, edges: edges)
            let level = indentLevel(relative, base: 0, step: indentStep)

            if current == nil {
                current = NSMutableAttributedString(attributedString: trimmedAttributed(line.text))
                currentIndent = level
                currentBold = line.isBold
                continue
            }

            let prevPlain = current!.string
            let soft = shouldJoin(
                prev: prevPlain,
                next: line.plain,
                prevSize: dominantSize(current!),
                nextSize: line.fontSize,
                median: median
            )

            // A bold line and a body line are different blocks even at the same size,
            // which is how most section headings are set.
            if soft && level <= currentIndent && line.isBold == currentBold {
                appendSoftWrapped(line.text, onto: current!)
            } else {
                flush()
                current = NSMutableAttributedString(attributedString: trimmedAttributed(line.text))
                currentIndent = level
                currentBold = line.isBold
            }
        }
        flush()

        var htmlParts: [String] = []
        var plainParts: [String] = []

        for (para, level) in zip(paragraphs, indentLevels) {
            let plain = para.string
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { continue }

            let size = dominantSize(para)
            let inline = inlineHTML(from: para)
            let isList = looksLikeListItem(plain)
            let bold = isMostlyBold(para)

            // "3.2 Method" and friends: numbering depth gives the heading level directly.
            if let numbered = numberedHeadingLevel(plain),
               plain.count < 200,
               bold || size >= headingThreshold {
                htmlParts.append("<h\(numbered)>\(inline)</h\(numbered)>")
            } else if size >= median * 1.45 || (size >= headingThreshold && plain.count < 120 && !plain.hasSuffix(".")) {
                let levelH = size >= median * 1.7 ? 1 : 2
                htmlParts.append("<h\(levelH)>\(inline)</h\(levelH)>")
            } else if size >= headingThreshold && plain.count < 180 {
                htmlParts.append("<h3>\(inline)</h3>")
            } else if bold && !isList && plain.count < 120 && !plain.hasSuffix(".") {
                // A short, wholly bold block at body size is a run-in section heading.
                htmlParts.append("<h3>\(inline)</h3>")
            } else if isList {
                htmlParts.append("<p class=\"list-item indent-\(min(level, 4))\">\(inline)</p>")
            } else if level >= 1 {
                htmlParts.append("<p class=\"indent-\(min(level, 4))\">\(inline)</p>")
            } else {
                htmlParts.append("<p>\(inline)</p>")
            }
            plainParts.append(plain)
        }

        return (plainParts.joined(separator: "\n\n"), htmlParts.joined(separator: "\n"))
    }

    // MARK: - Lines

    private static func lines(from attr: NSAttributedString) -> [Line] {
        var result: [Line] = []
        let full = attr.string as NSString
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byLines) { _, range, _, _ in
            let lineAttr = attr.attributedSubstring(from: range)
            let raw = lineAttr.string
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Line(text: NSAttributedString(string: ""), fontSize: 0, indent: 0, isBold: false))
                return
            }
            var fontSize: CGFloat = 0
            var styleIndent: CGFloat = 0
            var pageX = CGFloat.greatestFiniteMagnitude
            var boldLength = 0
            var styledLength = 0
            lineAttr.enumerateAttributes(in: NSRange(location: 0, length: lineAttr.length)) { attrs, range, _ in
                if let font = attrs[.font] as? NSFont {
                    fontSize = max(fontSize, font.pointSize)
                    styledLength += range.length
                    if font.fontDescriptor.symbolicTraits.contains(.bold) {
                        boldLength += range.length
                    }
                }
                if let x = attrs[xPositionKey] as? CGFloat {
                    pageX = min(pageX, x)
                }
                if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
                    styleIndent = max(styleIndent, ps.headIndent + ps.firstLineHeadIndent)
                }
            }
            if fontSize <= 0 { fontSize = 12 }
            var indent = pageX
            if indent == .greatestFiniteMagnitude {
                // No positional data (older fallback path): use what the attributes give.
                let leading = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
                indent = max(styleIndent, CGFloat(leading) * 6)
            }
            let bold = styledLength > 0 && Double(boldLength) / Double(styledLength) > 0.8
            result.append(Line(text: lineAttr, fontSize: fontSize, indent: indent, isBold: bold))
        }
        return result
    }

    // MARK: - Inline HTML (per glyph run)

    private static func inlineHTML(from attr: NSAttributedString) -> String {
        let trimmed = trimmedAttributed(attr)
        guard trimmed.length > 0 else { return "" }

        var html = ""
        let ns = trimmed.string as NSString
        trimmed.enumerateAttributes(in: NSRange(location: 0, length: trimmed.length)) { attrs, range, _ in
            var chunk = escapeHTML(ns.substring(with: range))
            // Soft newlines inside a paragraph become spaces
            chunk = chunk.replacingOccurrences(of: "\n", with: " ")
            if chunk.isEmpty { return }

            let font = attrs[.font] as? NSFont
            let bold = isBold(font)
            let italic = isItalic(font)
            let underline: Bool = {
                if let style = attrs[.underlineStyle] as? Int { return style != 0 }
                if let style = attrs[.underlineStyle] as? NSNumber { return style.intValue != 0 }
                return false
            }()
            let strike: Bool = {
                if let style = attrs[.strikethroughStyle] as? Int { return style != 0 }
                if let style = attrs[.strikethroughStyle] as? NSNumber { return style.intValue != 0 }
                return false
            }()
            let superKey = NSAttributedString.Key(rawValue: "NSSuperScript")
            let superscript = (attrs[superKey] as? Int).map { $0 > 0 }
                ?? (attrs[superKey] as? NSNumber).map { $0.intValue > 0 }
                ?? false
            let subscriptRun = (attrs[.baselineOffset] as? CGFloat).map { $0 < -0.5 }
                ?? (attrs[.baselineOffset] as? NSNumber).map { $0.doubleValue < -0.5 }
                ?? false

            if superscript { chunk = "<sup>\(chunk)</sup>" }
            else if subscriptRun { chunk = "<sub>\(chunk)</sub>" }
            if strike { chunk = "<s>\(chunk)</s>" }
            if underline { chunk = "<u>\(chunk)</u>" }
            if italic { chunk = "<em>\(chunk)</em>" }
            if bold { chunk = "<strong>\(chunk)</strong>" }

            html += chunk
        }
        return html
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBold(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.bold) { return true }
        if let dict = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
           let weight = dict[.weight] as? CGFloat, weight >= 0.23 {
            return true
        }
        let name = font.fontName.lowercased()
        let hints = ["bold", "black", "heavy", "semibold", "demibold", "demi-bold", "bd", "cmbx", "medi", "extrabold"]
        return hints.contains { name.contains($0) }
    }

    private static func isItalic(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { return true }
        let name = font.fontName.lowercased()
        return name.contains("italic") || name.contains("oblique") || name.contains("kursiv") || name.contains("cmti")
    }

    // MARK: - Joining / helpers

    private static func shouldJoin(prev: String, next: String, prevSize: CGFloat, nextSize: CGFloat, median: CGFloat) -> Bool {
        let a = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if prevSize >= median * 1.25 || nextSize >= median * 1.25 { return false }
        if abs(prevSize - nextSize) > 1.8 { return false }
        if a.hasSuffix("-") { return true }

        let endsSentence = [".", "?", "!", ":", ";"].contains { a.hasSuffix($0) }
        if endsSentence { return false }

        guard let first = b.unicodeScalars.first else { return false }
        if CharacterSet.lowercaseLetters.contains(first)
            || CharacterSet.decimalDigits.contains(first)
            || first == "(" {
            return true
        }
        if a.count < 95 && !endsSentence { return true }
        return false
    }

    private static func appendSoftWrapped(_ next: NSAttributedString, onto current: NSMutableAttributedString) {
        var piece = NSMutableAttributedString(attributedString: trimmedAttributed(next))
        if current.string.hasSuffix("-") {
            current.deleteCharacters(in: NSRange(location: current.length - 1, length: 1))
        } else if !current.string.hasSuffix(" ") && !piece.string.hasPrefix(" ") {
            let spaceAttrs = current.length > 0
                ? current.attributes(at: current.length - 1, effectiveRange: nil)
                : [:]
            current.append(NSAttributedString(string: " ", attributes: spaceAttrs))
        }
        // Drop leading whitespace on the next run
        while piece.length > 0 {
            let ch = (piece.string as NSString).character(at: 0)
            if ch == 32 || ch == 9 { piece.deleteCharacters(in: NSRange(location: 0, length: 1)) }
            else { break }
        }
        current.append(piece)
    }

    private static func trimmedAttributed(_ attr: NSAttributedString) -> NSAttributedString {
        let s = attr.string as NSString
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard trimmed.length > 0 else { return NSAttributedString(string: "") }
        let full = attr.string as NSString
        let range = full.range(of: trimmed as String)
        guard range.location != NSNotFound else { return attr }
        return attr.attributedSubstring(from: range)
    }

    private static func dominantSize(_ attr: NSAttributedString) -> CGFloat {
        var best: CGFloat = 12
        var bestCount = 0
        var counts: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            let key = (size * 2).rounded() / 2
            counts[key, default: 0] += range.length
            if counts[key, default: 0] > bestCount {
                bestCount = counts[key, default: 0]
                best = key
            }
        }
        return best
    }

    /// Left edges that many lines share — one per text column, so an indent is
    /// measured against its own column rather than the page.
    private static func columnEdges(from xs: [CGFloat]) -> [CGFloat] {
        let usable = xs.filter { $0.isFinite && $0 > 0 }
        guard usable.count > 4 else { return [] }
        var counts: [CGFloat: Int] = [:]
        for x in usable {
            counts[(x / 2).rounded() * 2, default: 0] += 1
        }
        let threshold = max(3, usable.count / 12)
        let edges = counts.filter { $0.value >= threshold }.keys.sorted()
        return edges.isEmpty ? [usable.min() ?? 0] : edges
    }

    private static func relativeIndent(_ x: CGFloat, edges: [CGFloat]) -> CGFloat {
        guard x.isFinite, !edges.isEmpty else { return 0 }
        var base = edges[0]
        for edge in edges where edge <= x + 1.5 { base = edge }
        return max(0, x - base)
    }

    private static func isMostlyBold(_ attr: NSAttributedString) -> Bool {
        var boldLength = 0
        var total = 0
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            total += range.length
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                boldLength += range.length
            }
        }
        return total > 0 && Double(boldLength) / Double(total) > 0.8
    }

    /// Heading level from a leading section number: "4" → 1, "4.2" → 2, "4.2.1" → 3.
    private static func numberedHeadingLevel(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^\d+(\.\d+)*\.?\s+\S"#, options: .regularExpression) != nil else {
            return nil
        }
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        let depth = digits.split(separator: ".").count
        return min(3, max(1, depth))
    }

    private static func indentLevel(_ indent: CGFloat, base: CGFloat, step: CGFloat) -> Int {
        let relative = indent - base
        guard relative > step * 0.45 else { return 0 }
        return min(4, Int((relative / step).rounded(.down)) + 1)
    }

    private static func looksLikeListItem(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("•") || t.hasPrefix("·") || t.hasPrefix("–") || t.hasPrefix("—") || t.hasPrefix("- ") || t.hasPrefix("* ") {
            return true
        }
        // 1.  12)  a.  (i)
        let pattern = #"^(\(([a-zA-Z0-9ivx]+)\)|([0-9]+[\.\)])|([a-zA-Z][\.\)])|[ivx]+\.)\s+"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    private static func medianSize(_ values: [CGFloat]) -> CGFloat? {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func plainFallbackHTML(_ raw: String) -> String {
        let paras = raw
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if paras.isEmpty { return "<p></p>" }
        var merged: [String] = []
        for line in paras {
            if let last = merged.last,
               !last.hasSuffix("."), !last.hasSuffix("?"), !last.hasSuffix("!"),
               let c = line.unicodeScalars.first,
               CharacterSet.lowercaseLetters.contains(c) || last.hasSuffix("-") {
                if last.hasSuffix("-") {
                    merged[merged.count - 1] = String(last.dropLast()) + line
                } else {
                    merged[merged.count - 1] = last + " " + line
                }
            } else {
                merged.append(line)
            }
        }
        return merged.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
    }
}
