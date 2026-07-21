import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InspectorPanel: View {
    @ObservedObject var presets: PresetStore
    @ObservedObject var settings: SettingsStore
    @Binding var showOriginalPDF: Bool
    var kind: DocumentKind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reading Lab")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PaperTheme.ink)

                if kind == .pdf {
                    Toggle("Show original PDF", isOn: $showOriginalPDF)
                        .toggleStyle(.switch)
                    Text("Default is extracted/reflow text. Switch back if extraction looks wrong.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                }

                presetSection
                Divider()
                overlaySection
                Divider()
                aidsSection
                Divider()
                typographySection
                Divider()
                visualSection
                Divider()
                ttsSection
            }
            .padding(16)
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
        .background(PaperTheme.paperDark.opacity(0.95))
    }

    private var presetBinding: Binding<ReadingPreset> {
        Binding(
            get: { presets.activePreset },
            set: { presets.upsert($0); presets.activePresetID = $0.id }
        )
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets").font(.headline)
            Picker("Active", selection: Binding(
                get: { presets.activePresetID },
                set: { if let id = $0 { presets.activate(id) } }
            )) {
                ForEach(presets.presets) { p in
                    Text(slotLabel(p)).tag(Optional(p.id))
                }
            }
            HStack {
                Button("New") {
                    let p = presets.create(named: "Preset \(presets.presets.count + 1)")
                    presets.activate(p.id)
                }
                Button("Duplicate") {
                    let p = presets.duplicate(presets.activePreset)
                    presets.activate(p.id)
                }
                Button("Delete") {
                    presets.delete(presets.activePreset.id)
                }
                .disabled(presets.presets.count <= 1)
            }
            .buttonStyle(.bordered)
            TextField("Name", text: Binding(
                get: { presets.activePreset.name },
                set: { presets.rename(presets.activePreset.id, to: $0) }
            ))
            Button("Set as preferred default") {
                settings.preferredPresetID = presets.activePreset.id
            }
            .buttonStyle(.borderedProminent)
            .tint(PaperTheme.accent)
        }
    }

    private func slotLabel(_ p: ReadingPreset) -> String {
        if let s = p.shortcutSlot { return "\(s) · \(p.name)" }
        return p.name
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Colour Overlay").font(.headline)
            Toggle("Enabled", isOn: presetBinding.overlayEnabled)
            Slider(value: presetBinding.overlayOpacity, in: 0...0.85) {
                Text("Opacity")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                ForEach(OverlaySwatches.all) { swatch in
                    Circle()
                        .fill(Color(hex: swatch.hex) ?? .gray)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(PaperTheme.chromeStroke))
                        .onTapGesture {
                            presets.updateActive {
                                $0.overlayColorHex = swatch.hex
                                $0.overlayEnabled = true
                            }
                        }
                        .help(swatch.name)
                }
            }
            OverlayColorPicker(presets: presets)
        }
    }

    private var aidsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Focus Aids").font(.headline)
            Toggle("Dim surround", isOn: presetBinding.dimSurroundEnabled)
            Slider(value: presetBinding.dimSurroundOpacity, in: 0...0.85) { Text("Dim") }
            Toggle("Line focus", isOn: presetBinding.lineFocusEnabled)
            Stepper("Visible lines: \(presets.activePreset.lineFocusLineCount)", value: presetBinding.lineFocusLineCount, in: 1...10)
            Toggle("Reading ruler", isOn: presetBinding.rulerEnabled)
            Slider(value: presetBinding.rulerHeight, in: 24...120) { Text("Ruler height") }
            Toggle("Page focus", isOn: presetBinding.pageFocusEnabled)
        }
    }

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Typography").font(.headline)
            Picker("Font", selection: presetBinding.fontFamily) {
                Text("OpenDyslexic").tag("OpenDyslexic")
                Text("Georgia").tag("Georgia")
                Text("Palatino").tag("Palatino")
                Text("New York").tag(".NewYork-Regular")
                Text("SF Pro").tag(".AppleSystemUIFont")
            }
            Slider(value: presetBinding.fontSize, in: 14...36) { Text("Size \(Int(presets.activePreset.fontSize))") }
            Slider(value: presetBinding.lineSpacing, in: 0...24) { Text("Line spacing") }
            Slider(value: presetBinding.paragraphSpacing, in: 0...40) { Text("Paragraph") }
            Slider(value: presetBinding.characterSpacing, in: 0...3) { Text("Character") }
            Slider(value: presetBinding.wordSpacing, in: 0...8) { Text("Word") }
            Slider(value: presetBinding.readingWidth, in: 400...1100) { Text("Width") }
            Slider(value: presetBinding.margins, in: 16...120) { Text("Margins") }
            ColorPicker("Text", selection: Binding(
                get: { presets.activePreset.textColor },
                set: { c in presets.updateActive { $0.textColorHex = c.toHexRGB() } }
            ))
            ColorPicker("Background", selection: Binding(
                get: { presets.activePreset.backgroundColor },
                set: { c in presets.updateActive { $0.backgroundColorHex = c.toHexRGB() } }
            ))
        }
    }

    private var visualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visual / Zoom").font(.headline)
            Slider(value: presetBinding.zoomPercent, in: 50...250) {
                Text("Zoom \(Int(presets.activePreset.zoomPercent))%")
            }
            Toggle("Continuous scroll", isOn: presetBinding.continuousScroll)
            Toggle("Invert colours", isOn: presetBinding.invertColors)
            Slider(value: presetBinding.brightness, in: -0.5...0.5) { Text("Brightness") }
            Slider(value: presetBinding.contrast, in: -0.5...0.5) { Text("Contrast") }
            Slider(value: presetBinding.saturation, in: -1...1) { Text("Saturation") }
        }
    }

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text to Speech").font(.headline)
            Toggle("Prefer OpenAI TTS", isOn: presetBinding.ttsPreferOpenAI)
            SecureField("OpenAI API Key", text: $settings.openAIAPIKey)
            Picker("Voice", selection: presetBinding.openAIVoice) {
                Text("nova").tag("nova")
                Text("alloy").tag("alloy")
                Text("echo").tag("echo")
                Text("fable").tag("fable")
                Text("onyx").tag("onyx")
                Text("shimmer").tag("shimmer")
            }
            Slider(value: presetBinding.ttsSpeed, in: 0.5...2.5) {
                Text("Speed \(String(format: "%.2f", presets.activePreset.ttsSpeed))×")
            }
        }
    }
}

private struct OverlayColorPicker: View {
    @ObservedObject var presets: PresetStore
    var body: some View {
        ColorPicker("Custom overlay", selection: Binding(
            get: { presets.activePreset.overlayColor },
            set: { c in presets.updateActive { $0.overlayColorHex = c.toHexRGB() } }
        ))
    }
}
