import Foundation
import PDFKit
import UniformTypeIdentifiers
import SwiftUI

struct ReaderDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.pdf, .epub, .html, UTType(filenameExtension: "xhtml") ?? .html]
    }

    static var writableContentTypes: [UTType] { [] }

    var data: Data
    var kind: DocumentKind
    var sourceURL: URL?

    init(data: Data = Data(), kind: DocumentKind = .pdf, sourceURL: URL? = nil) {
        self.data = data
        self.kind = kind
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        let name = configuration.file.filename ?? "document.pdf"
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": self.kind = .pdf
        case "epub": self.kind = .epub
        default: self.kind = .html
        }
        self.sourceURL = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct EPUBContent {
    var spineHTMLs: [(title: String, html: String, baseURL: URL)]
    var toc: [(title: String, index: Int)]
}

enum EPUBLoader {
    static func load(from data: Data) throws -> EPUBContent {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let zipURL = temp.appendingPathComponent("book.epub")
        try data.write(to: zipURL)

        let extractDir = temp.appendingPathComponent("extracted", isDirectory: true)
        try unzip(zipURL, to: extractDir)

        let container = extractDir.appendingPathComponent("META-INF/container.xml")
        let containerXML = try String(contentsOf: container, encoding: .utf8)
        guard let opfRel = firstMatch(containerXML, pattern: #"full-path=\"([^\"]+)\""#) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let opfURL = extractDir.appendingPathComponent(opfRel)
        let opfDir = opfURL.deletingLastPathComponent()
        let opf = try String(contentsOf: opfURL, encoding: .utf8)

        var idToHref: [String: String] = [:]
        let itemRegex = try NSRegularExpression(pattern: #"<item[^>]+id=\"([^\"]+)\"[^>]+href=\"([^\"]+)\""#)
        let itemRegex2 = try NSRegularExpression(pattern: #"<item[^>]+href=\"([^\"]+)\"[^>]+id=\"([^\"]+)\""#)
        let ns = opf as NSString
        for m in itemRegex.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let href = ns.substring(with: m.range(at: 2))
            idToHref[id] = href
        }
        for m in itemRegex2.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let id = ns.substring(with: m.range(at: 2))
            idToHref[id] = href
        }

        var spine: [String] = []
        let spineRegex = try NSRegularExpression(pattern: #"<itemref[^>]+idref=\"([^\"]+)\""#)
        for m in spineRegex.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            spine.append(ns.substring(with: m.range(at: 1)))
        }

        var chapters: [(title: String, html: String, baseURL: URL)] = []
        var toc: [(title: String, index: Int)] = []
        for (idx, id) in spine.enumerated() {
            guard let href = idToHref[id] else { continue }
            let fileURL = opfDir.appendingPathComponent(href)
            guard let html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let title = firstMatch(html, pattern: #"<title[^>]*>([^<]+)</title>"#) ?? "Chapter \(idx + 1)"
            chapters.append((title, html, fileURL.deletingLastPathComponent()))
            toc.append((title, idx))
        }
        return EPUBContent(spineHTMLs: chapters, toc: toc)
    }

    private static func unzip(_ zipURL: URL, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", dest.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func firstMatch(_ string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = string as NSString
        guard let m = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
