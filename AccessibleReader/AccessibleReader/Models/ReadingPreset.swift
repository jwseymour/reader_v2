import SwiftUI
import Foundation

struct ReadingPreset: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var shortcutSlot: Int?

    // Colours
    var overlayEnabled: Bool
    var overlayColorHex: String
    var overlayOpacity: Double
    var backgroundColorHex: String
    var textColorHex: String

    // Visual adjustments (mainly original PDF)
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var gamma: Double
    var invertColors: Bool

    // Zoom / layout
    var zoomPercent: Double
    var continuousScroll: Bool
    var readingWidth: Double
    var margins: Double

    // Typography (extracted / EPUB / HTML)
    var fontFamily: String
    var fontSize: Double
    var lineSpacing: Double
    var paragraphSpacing: Double
    var characterSpacing: Double
    var wordSpacing: Double

    // Reading aids
    var dimSurroundEnabled: Bool
    var dimSurroundOpacity: Double
    var rulerEnabled: Bool
    var rulerHeight: Double
    var rulerOpacity: Double
    var rulerColorHex: String
    var rulerSoftness: Double
    var lineFocusEnabled: Bool
    var lineFocusLineCount: Int
    var lineFocusFade: Double
    var pageFocusEnabled: Bool

    // TTS prefs stored with preset
    var ttsSpeed: Double
    var ttsPreferOpenAI: Bool
    var openAIVoice: String

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        shortcutSlot: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.shortcutSlot = shortcutSlot

        self.overlayEnabled = false
        self.overlayColorHex = "#F5E6C8"
        self.overlayOpacity = 0.35
        self.backgroundColorHex = "#F4F6F4"
        self.textColorHex = "#1C241F"

        self.brightness = 0
        self.contrast = 0
        self.saturation = 0
        self.gamma = 1
        self.invertColors = false

        self.zoomPercent = 100
        self.continuousScroll = true
        self.readingWidth = 720
        self.margins = 48

        self.fontFamily = "OpenDyslexic"
        self.fontSize = 16
        self.lineSpacing = 8
        self.paragraphSpacing = 16
        self.characterSpacing = 0.4
        self.wordSpacing = 2

        // Suggested personal lean: line focus + dim-surround
        self.dimSurroundEnabled = true
        self.dimSurroundOpacity = 0.45
        self.rulerEnabled = false
        self.rulerHeight = 48
        self.rulerOpacity = 0.25
        self.rulerColorHex = "#C4A574"
        self.rulerSoftness = 12
        self.lineFocusEnabled = true
        self.lineFocusLineCount = 3
        self.lineFocusFade = 0.55
        self.pageFocusEnabled = false

        self.ttsSpeed = 1.0
        self.ttsPreferOpenAI = true
        self.openAIVoice = "nova"
    }

    static var starter: ReadingPreset {
        var p = ReadingPreset(name: "Daily")
        p.shortcutSlot = 1
        return p
    }
}

extension ReadingPreset {
    var overlayColor: Color { Color(hex: overlayColorHex) ?? .yellow }
    var backgroundColor: Color { Color(hex: backgroundColorHex) ?? Color(red: 0.97, green: 0.95, blue: 0.91) }
    var textColor: Color { Color(hex: textColorHex) ?? .primary }
    var rulerColor: Color { Color(hex: rulerColorHex) ?? .brown }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let a, r, g, b: Double
        if s.count == 8 {
            a = Double((value & 0xFF000000) >> 24) / 255
            r = Double((value & 0x00FF0000) >> 16) / 255
            g = Double((value & 0x0000FF00) >> 8) / 255
            b = Double(value & 0x000000FF) / 255
        } else {
            a = 1
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHexRGB() -> String {
        #if os(macOS)
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return "#FFFFFF" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        return "#FFFFFF"
        #endif
    }
}
