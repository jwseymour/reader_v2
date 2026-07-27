import Foundation
import AppKit
import SwiftUI

enum ReaderFont {
    /// OpenDyslexic’s em box reads ~18% larger than Georgia at the same point size.
    static func opticalScale(for family: String) -> CGFloat {
        family.localizedCaseInsensitiveContains("opendyslexic") ? 0.82 : 1.0
    }

    static func displaySize(for preset: ReadingPreset) -> CGFloat {
        CGFloat(preset.fontSize) * opticalScale(for: preset.fontFamily)
    }

    /// Resolve a usable PostScript / family name after registration.
    static func resolvedName(for family: String) -> String {
        if family.hasPrefix(".") { return family }
        if let font = NSFont(name: family, size: 16) {
            return font.fontName
        }
        // OpenDyslexic variants
        let candidates = [
            family,
            "\(family)-Regular",
            "OpenDyslexic",
            "OpenDyslexic-Regular",
            "OpenDyslexic Regular"
        ]
        for name in candidates {
            if let font = NSFont(name: name, size: 16) {
                return font.fontName
            }
        }
        // Search installed fonts
        for ps in NSFontManager.shared.availableFonts where ps.localizedCaseInsensitiveContains("opendyslexic") {
            return ps
        }
        return family
    }

    static func swiftUIFont(for preset: ReadingPreset) -> Font {
        let size = displaySize(for: preset)
        if preset.fontFamily.hasPrefix(".") {
            return .system(size: size)
        }
        let name = resolvedName(for: preset.fontFamily)
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size)
    }

    static func openDyslexicFaceCSS() -> String {
        guard let url = Bundle.main.url(forResource: "OpenDyslexic-Regular", withExtension: "otf") else {
            return ""
        }
        return """
        @font-face {
          font-family: 'OpenDyslexic';
          src: url('\(url.absoluteString)') format('opentype');
          font-weight: normal;
          font-style: normal;
        }
        """
    }
}
