import SwiftUI

enum PaperTheme {
    static let paper = Color(red: 0.97, green: 0.94, blue: 0.88)
    static let paperDark = Color(red: 0.92, green: 0.87, blue: 0.78)
    static let ink = Color(red: 0.22, green: 0.17, blue: 0.12)
    static let accent = Color(red: 0.55, green: 0.38, blue: 0.22)
    static let chromeStroke = Color.black.opacity(0.08)

    static func chrome(for preset: ReadingPreset) -> Color {
        preset.backgroundColor
    }
}

struct OverlaySwatch: Identifiable {
    let id = UUID()
    let name: String
    let hex: String
}

enum OverlaySwatches {
    static let all: [OverlaySwatch] = [
        .init(name: "Cream", hex: "#F5E6C8"),
        .init(name: "Light Yellow", hex: "#FFF3B0"),
        .init(name: "Light Blue", hex: "#D6EAF8"),
        .init(name: "Mint", hex: "#D5F5E3"),
        .init(name: "Pink", hex: "#F5D0E6"),
        .init(name: "Grey", hex: "#D5D8DC")
    ]
}
