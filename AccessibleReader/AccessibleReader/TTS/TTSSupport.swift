import Foundation
import CryptoKit

actor TTSCache {
    private let directory: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AccessibleReader/TTSCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    func url(forKey key: String) -> URL {
        directory.appendingPathComponent(key + ".mp3")
    }

    func data(forKey key: String) -> Data? {
        let url = url(forKey: key)
        return try? Data(contentsOf: url)
    }

    func store(_ data: Data, forKey key: String) {
        try? data.write(to: url(forKey: key), options: .atomic)
    }

    static func key(provider: String, voice: String, text: String) -> String {
        let payload = "\(provider)|\(voice)|\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct OpenAITTSClient {
    var apiKey: String
    var voice: String = "nova"
    var model: String = "tts-1-hd"

    func synthesize(text: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw TTSError.noAPIKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TTSError.apiFailed(String(data: data, encoding: .utf8) ?? "TTS request failed")
        }
        return data
    }
}

enum TTSError: LocalizedError {
    case noAPIKey
    case apiFailed(String)
    case emptyText

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "OpenAI API key not configured"
        case .apiFailed(let m): return m
        case .emptyText: return "Nothing to speak"
        }
    }
}

struct TTSParagraph: Identifiable, Hashable {
    let id: Int
    let pageIndex: Int
    let text: String
    let sentences: [String]
}

enum TTSTextSplitter {
    static func paragraphs(from pages: [ExtractedPage]) -> [TTSParagraph] {
        var result: [TTSParagraph] = []
        var id = 0
        for page in pages {
            let blocks = page.text
                .components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Group into paragraph-ish chunks (~400–800 chars)
            var buffer = ""
            for block in blocks {
                if buffer.isEmpty {
                    buffer = block
                } else if buffer.count + block.count < 700 {
                    buffer += "\n\n" + block
                } else {
                    result.append(make(id: id, page: page.pageIndex, text: buffer))
                    id += 1
                    buffer = block
                }
            }
            if !buffer.isEmpty {
                result.append(make(id: id, page: page.pageIndex, text: buffer))
                id += 1
            }
        }
        return result
    }

    static func paragraphs(from plain: String, pageIndex: Int = 0) -> [TTSParagraph] {
        paragraphs(from: [ExtractedPage(id: pageIndex, pageIndex: pageIndex, text: plain, html: "<p></p>")])
    }

    private static func make(id: Int, page: Int, text: String) -> TTSParagraph {
        TTSParagraph(id: id, pageIndex: page, text: text, sentences: splitSentences(text))
    }

    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }
}
