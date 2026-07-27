import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InspectorPanel: View {
    @ObservedObject var presets: PresetStore
    @ObservedObject var settings: SettingsStore
    @Binding var showOriginalPDF: Bool
    var kind: DocumentKind

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if kind == .pdf {
                        pdfModeSection
                    }
                    presetSection
                    overlaySection
                    aidsSection
                    typographySection
                    visualSection
                    ttsSection
                }
                .padding(14)
            }
        }
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
        .background(PaperTheme.panel)
        .preferredColorScheme(.light)
        .foregroundStyle(PaperTheme.ink)
        .tint(PaperTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading Lab")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(PaperTheme.ink)
                Text("Tune comfort, then save as a preset")
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.inkTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(PaperTheme.elevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PaperTheme.stroke).frame(height: 1)
        }
    }

    private var presetBinding: Binding<ReadingPreset> {
        Binding(
            get: { presets.activePreset },
            set: { presets.upsert($0); presets.activePresetID = $0.id }
        )
    }

    private var pdfModeSection: some View {
        InspectorSection(title: "Document View", icon: "doc.richtext") {
            HStack(spacing: 8) {
                modeChip(
                    title: "Reflow text",
                    active: !showOriginalPDF,
                    action: { showOriginalPDF = false }
                )
                modeChip(
                    title: "Original PDF",
                    active: showOriginalPDF,
                    action: { showOriginalPDF = true }
                )
            }
            Text(showOriginalPDF
                 ? "Visual PDF page — overlays and zoom still apply."
                 : "Extracted text — fonts, spacing, and TTS work best here.")
                .font(.system(size: 11))
                .foregroundStyle(PaperTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modeChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .foregroundStyle(active ? Color.white : PaperTheme.ink)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? PaperTheme.accent : PaperTheme.mist)
                )
        }
        .buttonStyle(.plain)
    }

    private var presetSection: some View {
        InspectorSection(title: "Presets", icon: "square.stack.3d.up") {
            Picker("Active", selection: Binding(
                get: { presets.activePresetID },
                set: { if let id = $0 { presets.activate(id) } }
            )) {
                ForEach(presets.presets) { p in
                    Text(slotLabel(p)).tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            TextField("Preset name", text: Binding(
                get: { presets.activePreset.name },
                set: { presets.rename(presets.activePreset.id, to: $0) }
            ))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
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
            .controlSize(.small)

            Button {
                settings.preferredPresetID = presets.activePreset.id
            } label: {
                Label("Set as default for new papers", systemImage: "star.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PaperTheme.accent)
            .controlSize(.small)
        }
    }

    private func slotLabel(_ p: ReadingPreset) -> String {
        if let s = p.shortcutSlot { return "⌘\(s)  \(p.name)" }
        return p.name
    }

    private var overlaySection: some View {
        InspectorSection(title: "Colour Overlay", icon: "circle.lefthalf.filled") {
            Toggle(isOn: presetBinding.overlayEnabled) {
                Text("Enable overlay")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(PaperTheme.accent)

            if presets.activePreset.overlayEnabled {
                LabeledSlider(
                    label: "Strength",
                    value: presetBinding.overlayOpacity,
                    range: 0...0.85,
                    display: "\(Int(presets.activePreset.overlayOpacity * 100))%"
                )

                PaperTheme.sectionLabel("Quick colours")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
                    ForEach(OverlaySwatches.all) { swatch in
                        let selected = presets.activePreset.overlayColorHex
                            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                            .uppercased()
                            == swatch.hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
                        Circle()
                            .fill(Color(hex: swatch.hex) ?? .gray)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(selected ? PaperTheme.accent : PaperTheme.strokeStrong, lineWidth: selected ? 2.5 : 1)
                            )
                            .onTapGesture {
                                presets.updateActive {
                                    $0.overlayColorHex = swatch.hex
                                    $0.overlayEnabled = true
                                }
                            }
                            .help(swatch.name)
                    }
                }

                ColorPicker("Custom", selection: Binding(
                    get: { presets.activePreset.overlayColor },
                    set: { c in presets.updateActive { $0.overlayColorHex = c.toHexRGB() } }
                ))
            }
        }
    }

    private var aidsSection: some View {
        InspectorSection(title: "Focus Aids", icon: "eye") {
            aidToggle("Dim surround", isOn: presetBinding.dimSurroundEnabled, hint: "Darken outside the reading band — follows the mouse")
            if presets.activePreset.dimSurroundEnabled {
                LabeledSlider(
                    label: "Dim amount",
                    value: presetBinding.dimSurroundOpacity,
                    range: 0...0.85,
                    display: "\(Int(presets.activePreset.dimSurroundOpacity * 100))%"
                )
            }

            Divider().opacity(0.5)

            aidToggle("Line focus", isOn: presetBinding.lineFocusEnabled, hint: "Keep a few lines bright — follows the mouse")
            if presets.activePreset.lineFocusEnabled {
                Stepper(
                    "Visible lines: \(presets.activePreset.lineFocusLineCount)",
                    value: presetBinding.lineFocusLineCount,
                    in: 1...10
                )
                .font(.system(size: 12))
                LabeledSlider(
                    label: "Edge softness",
                    value: presetBinding.lineFocusFade,
                    range: 0.15...0.9,
                    display: String(format: "%.0f%%", presets.activePreset.lineFocusFade * 100)
                )
            }

            Divider().opacity(0.5)

            aidToggle("Reading ruler", isOn: presetBinding.rulerEnabled, hint: "Drag or use J / K")
            if presets.activePreset.rulerEnabled {
                LabeledSlider(
                    label: "Height",
                    value: presetBinding.rulerHeight,
                    range: 24...120,
                    display: "\(Int(presets.activePreset.rulerHeight)) pt"
                )
            }

            Divider().opacity(0.5)

            aidToggle("Page focus", isOn: presetBinding.pageFocusEnabled, hint: "Vignette top and bottom of the page")
        }
    }

    private func aidToggle(_ title: String, isOn: Binding<Bool>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) {
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(PaperTheme.accent)
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(PaperTheme.inkTertiary)
        }
    }

    private var typographySection: some View {
        InspectorSection(title: "Typography", icon: "textformat", initiallyExpanded: false) {
            Picker("Font", selection: presetBinding.fontFamily) {
                Text("OpenDyslexic").tag("OpenDyslexic")
                Text("Georgia").tag("Georgia")
                Text("Palatino").tag("Palatino")
                Text("New York").tag(".NewYork-Regular")
                Text("SF Pro").tag(".AppleSystemUIFont")
            }

            LabeledSlider(label: "Size", value: presetBinding.fontSize, range: 10...32,
                          display: "\(Int(presets.activePreset.fontSize)) pt")
            if presets.activePreset.fontFamily.localizedCaseInsensitiveContains("opendyslexic") {
                Text("OpenDyslexic is scaled optically so point sizes match other fonts.")
                    .font(.system(size: 10))
                    .foregroundStyle(PaperTheme.inkTertiary)
            }
            LabeledSlider(label: "Line spacing", value: presetBinding.lineSpacing, range: 0...24,
                          display: "\(Int(presets.activePreset.lineSpacing))")
            LabeledSlider(label: "Paragraph", value: presetBinding.paragraphSpacing, range: 0...40,
                          display: "\(Int(presets.activePreset.paragraphSpacing))")
            LabeledSlider(label: "Character", value: presetBinding.characterSpacing, range: 0...3,
                          display: String(format: "%.1f", presets.activePreset.characterSpacing))
            LabeledSlider(label: "Word", value: presetBinding.wordSpacing, range: 0...8,
                          display: String(format: "%.1f", presets.activePreset.wordSpacing))
            LabeledSlider(label: "Column width", value: presetBinding.readingWidth, range: 400...1100,
                          display: "\(Int(presets.activePreset.readingWidth))")
            LabeledSlider(label: "Margins", value: presetBinding.margins, range: 16...120,
                          display: "\(Int(presets.activePreset.margins))")

            ColorPicker("Text colour", selection: Binding(
                get: { presets.activePreset.textColor },
                set: { c in presets.updateActive { $0.textColorHex = c.toHexRGB() } }
            ))
            ColorPicker("Page background", selection: Binding(
                get: { presets.activePreset.backgroundColor },
                set: { c in presets.updateActive { $0.backgroundColorHex = c.toHexRGB() } }
            ))
        }
    }

    private var visualSection: some View {
        InspectorSection(title: "Display", icon: "slider.horizontal.3", initiallyExpanded: false) {
            LabeledSlider(label: "Zoom", value: presetBinding.zoomPercent, range: 50...250,
                          display: "\(Int(presets.activePreset.zoomPercent))%")
            Toggle("Continuous scroll", isOn: presetBinding.continuousScroll)
                .font(.system(size: 12, weight: .medium))
                .tint(PaperTheme.accent)
            Toggle("Invert colours", isOn: presetBinding.invertColors)
                .font(.system(size: 12, weight: .medium))
                .tint(PaperTheme.accent)
            LabeledSlider(label: "Brightness", value: presetBinding.brightness, range: -0.5...0.5,
                          display: String(format: "%+.0f%%", presets.activePreset.brightness * 100))
            LabeledSlider(label: "Contrast", value: presetBinding.contrast, range: -0.5...0.5,
                          display: String(format: "%+.0f%%", presets.activePreset.contrast * 100))
            LabeledSlider(label: "Saturation", value: presetBinding.saturation, range: -1...1,
                          display: String(format: "%+.0f%%", presets.activePreset.saturation * 100))
        }
    }

    private var ttsSection: some View {
        InspectorSection(title: "Speech", icon: "speaker.wave.2", initiallyExpanded: false) {
            Toggle("Prefer OpenAI TTS", isOn: presetBinding.ttsPreferOpenAI)
                .font(.system(size: 12, weight: .medium))
                .tint(PaperTheme.accent)
            SecureField("OpenAI API Key", text: $settings.openAIAPIKey)
                .textFieldStyle(.roundedBorder)
            Text("From Keychain or `.env` (OPENAI_API_KEY). OpenAI Audio Speech API.")
                .font(.system(size: 10))
                .foregroundStyle(PaperTheme.inkTertiary)
            Picker("Voice", selection: presetBinding.openAIVoice) {
                Text("nova").tag("nova")
                Text("alloy").tag("alloy")
                Text("echo").tag("echo")
                Text("fable").tag("fable")
                Text("onyx").tag("onyx")
                Text("shimmer").tag("shimmer")
            }
            LabeledSlider(label: "Speed", value: presetBinding.ttsSpeed, range: 0.5...2.5,
                          display: String(format: "%.2f×", presets.activePreset.ttsSpeed))
            Text("Model: \(settings.openAITTSModel). Play from the bottom bar or ⌃Space.")
                .font(.system(size: 10))
                .foregroundStyle(PaperTheme.inkTertiary)
        }
    }
}
