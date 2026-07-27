import Foundation
import PDFKit
import AppKit

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
        var indent: CGFloat
        var isBlank: Bool { text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var plain: String { text.string }
    }

    private static func structure(page: PDFPage) -> (plain: String, html: String) {
        if let attr = attributedString(for: page), attr.length > 0 {
            return html(from: attr)
        }
        let raw = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (raw, plainFallbackHTML(raw))
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
        let indents = lines.map(\.indent).filter { $0 > 0 }
        let baseIndent = medianSize(indents) ?? 0
        let indentStep = max(12, median * 0.9)

        var paragraphs: [NSAttributedString] = []
        var indentLevels: [Int] = []
        var current: NSMutableAttributedString?
        var currentIndent = 0

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

            let level = indentLevel(line.indent, base: baseIndent, step: indentStep)

            if current == nil {
                current = NSMutableAttributedString(attributedString: trimmedAttributed(line.text))
                currentIndent = level
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

            if soft && level <= currentIndent {
                appendSoftWrapped(line.text, onto: current!)
            } else {
                flush()
                current = NSMutableAttributedString(attributedString: trimmedAttributed(line.text))
                currentIndent = level
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

            if size >= median * 1.45 || (size >= headingThreshold && plain.count < 120 && !plain.hasSuffix(".")) {
                let levelH = size >= median * 1.7 ? 1 : 2
                htmlParts.append("<h\(levelH)>\(inline)</h\(levelH)>")
            } else if size >= headingThreshold && plain.count < 180 {
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
                result.append(Line(text: NSAttributedString(string: ""), fontSize: 0, indent: 0))
                return
            }
            var fontSize: CGFloat = 12
            var indent: CGFloat = 0
            lineAttr.enumerateAttributes(in: NSRange(location: 0, length: lineAttr.length)) { attrs, _, _ in
                if let font = attrs[.font] as? NSFont {
                    fontSize = max(fontSize, font.pointSize)
                }
                if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
                    indent = max(indent, ps.headIndent + ps.firstLineHeadIndent)
                }
            }
            // Leading whitespace as a fallback indent signal
            let leading = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            indent = max(indent, CGFloat(leading) * 6)
            result.append(Line(text: lineAttr, fontSize: fontSize, indent: indent))
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
