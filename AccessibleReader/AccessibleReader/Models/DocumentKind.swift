import Foundation
import UniformTypeIdentifiers

enum DocumentKind: String, Codable {
    case pdf
    case epub
    case html

    static func detect(url: URL) -> DocumentKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "epub": return .epub
        case "html", "htm", "xhtml": return .html
        default:
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                if type.conforms(to: .pdf) { return .pdf }
                if type.conforms(to: .epub) || type.identifier.contains("epub") { return .epub }
                if type.conforms(to: .html) || type.conforms(to: .xml) { return .html }
            }
            return .html
        }
    }
}

extension UTType {
    static var epub: UTType {
        UTType(filenameExtension: "epub") ?? UTType(exportedAs: "org.idpf.epub-container")
    }
}
