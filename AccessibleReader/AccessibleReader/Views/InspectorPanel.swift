import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InspectorPanel: View {
    @ObservedObject var presets: PresetStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var zoteroSync: ZoteroSyncStore
    @ObservedObject var zoteroLinks: ZoteroLinkStore
    @Binding var showOriginalPDF: Bool
    var kind: DocumentKind
    var documentKey: String?
    var annotations: [PDFHighlightAnnotation] = []
    var onJumpToAnnotation: (Int) -> Void = { _ in }
    var onDeleteAnnotation: (UUID) -> Void = { _ in }
    var onExportRequested: () -> Void = {}
    @State private var showLinkPicker = false

    private var zoteroLink: ZoteroDocumentLink? {
        documentKey.flatMap { zoteroLinks.link(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if kind == .pdf {
                        pdfModeSection
                        annotationsSection
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

    /// Highlights created in Original PDF mode (⌘⇧H on a text selection). Live-synced
    /// to Zotero via `ZoteroSyncStore` once this document is linked (`zoteroStatusRow`);
    /// the "Export Highlights to PDF" bridge is a fallback for documents that aren't.
    private var annotationsSection: some View {
        InspectorSection(title: "Highlights", icon: "highlighter", initiallyExpanded: false) {
            zoteroStatusRow
            if annotations.isEmpty {
                Text("Select text in Original PDF mode and press ⌘⇧H to add a highlight.")
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(annotations) { annotation in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color(hex: annotation.color) ?? .yellow)
                                .frame(width: 10, height: 10)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(annotation.matchText)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(2)
                                if !annotation.comment.isEmpty {
                                    Text(annotation.comment)
                                        .font(.system(size: 11))
                                        .foregroundStyle(PaperTheme.inkTertiary)
                                        .lineLimit(2)
                                }
                                if !annotation.tags.isEmpty {
                                    Text(annotation.tags.joined(separator: " · "))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(PaperTheme.accent)
                                        .lineLimit(1)
                                }
                                Button("Page \(annotation.pageIndex + 1)") {
                                    onJumpToAnnotation(annotation.pageIndex)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(PaperTheme.accent)
                            }
                            Spacer(minLength: 0)
                            Button {
                                onDeleteAnnotation(annotation.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(PaperTheme.inkTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(PaperTheme.mist)
                        )
                    }
                }

                if zoteroLink == nil {
                    Button("Export Highlights to PDF…", action: onExportRequested)
                        .buttonStyle(.bordered)
                        .tint(PaperTheme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var zoteroStatusRow: some View {
        HStack(spacing: 6) {
            if let link = zoteroLink {
                Circle().fill(zoteroStatusColor).frame(width: 7, height: 7)
                Text(zoteroStatusText(linkedVia: link.resolvedVia))
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.inkTertiary)
            } else {
                Text("Not linked to Zotero")
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.inkTertiary)
                Spacer(minLength: 0)
                Button("Link to Zotero…") { showLinkPicker = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PaperTheme.accent)
            }
        }
        .padding(.bottom, 4)
        .sheet(isPresented: $showLinkPicker) {
            if let documentKey {
                ZoteroLinkPickerView(documentKey: documentKey) { attachmentKey in
                    zoteroLinks.setLink(ZoteroDocumentLink(
                        documentKey: documentKey,
                        libraryID: zoteroSync.userID ?? 0,
                        attachmentItemKey: attachmentKey,
                        resolvedVia: "manual"
                    ))
                }
            }
        }
    }

    private var zoteroStatusColor: Color {
        switch zoteroSync.status {
        case .error, .offline: return .red
        case .syncing: return .yellow
        default: return .green
        }
    }

    private func zoteroStatusText(linkedVia: String) -> String {
        switch zoteroSync.status {
        case .syncing: return "Syncing with Zotero…"
        case .offline: return "Zotero offline — will retry"
        case .error(let message): return message
        default: return "Synced with Zotero"
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
            HStack(spacing: 6) {
                Text("Exact")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PaperTheme.inkSecondary)
                TextField("100", value: Binding(
                    get: { presets.activePreset.zoomPercent },
                    set: { v in presets.updateActive { $0.zoomPercent = min(250, max(50, v)) } }
                ), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                Text("%")
                    .font(.system(size: 12))
                    .foregroundStyle(PaperTheme.inkTertiary)
                Spacer()
            }
            LabeledSlider(label: "Gamma", value: presetBinding.gamma, range: 0.3...2.5,
                          display: String(format: "%.2f", presets.activePreset.gamma))
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
            PaperTheme.sectionLabel("Voice engine")
            Picker("Voice Engine", selection: presetBinding.ttsPreferOpenAI) {
                Text("OpenAI").tag(true)
                Text("macOS (Free)").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if presets.activePreset.ttsPreferOpenAI {
                SecureField("OpenAI API Key", text: $settings.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 5) {
                    Image(systemName: settings.apiKeyRejected ? "exclamationmark.triangle.fill" : "key.fill")
                        .font(.system(size: 9))
                    Text(settings.apiKeyRejected
                         ? "OpenAI rejected this key"
                         : settings.apiKeySource.label)
                    .font(.system(size: 10))
                }
                .foregroundStyle(settings.apiKeyRejected ? PaperTheme.warning : PaperTheme.inkTertiary)
                Text("`.env.local` / `.env` wins unless you type a key here. OpenAI Audio Speech API. If a request fails, playback pauses with an error rather than silently switching engines.")
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
                Text("Model: \(settings.openAITTSModel).")
                    .font(.system(size: 10))
                    .foregroundStyle(PaperTheme.inkTertiary)
            } else {
                Text("Uses the built-in macOS voice — no API key or network needed.")
                    .font(.system(size: 10))
                    .foregroundStyle(PaperTheme.inkTertiary)
            }
            LabeledSlider(label: "Speed", value: presetBinding.ttsSpeed, range: 0.5...2.5,
                          display: String(format: "%.2f×", presets.activePreset.ttsSpeed))
            Text("Play from the bottom bar or ⌃Space.")
                .font(.system(size: 10))
                .foregroundStyle(PaperTheme.inkTertiary)

            Divider().opacity(0.5)

            PaperTheme.sectionLabel("Highlight while speaking")
            Picker("Highlight style", selection: highlightModeBinding) {
                Text("Whole sentence").tag(TTSHighlightMode.sentence)
                Text("Moving word window").tag(TTSHighlightMode.wordWindow)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if presets.activePreset.effectiveTTSHighlightMode == .wordWindow {
                Stepper(
                    "Words around: \(presets.activePreset.effectiveTTSHighlightWindowSize)",
                    value: highlightWindowBinding,
                    in: 1...5
                )
                .font(.system(size: 12))
                Text("Highlights the spoken word plus \(presets.activePreset.effectiveTTSHighlightWindowSize) word(s) on each side, moving along as it's read.")
                    .font(.system(size: 10))
                    .foregroundStyle(PaperTheme.inkTertiary)
            } else {
                Text("Highlights the whole sentence currently being spoken.")
                    .font(.system(size: 10))
                    .foregroundStyle(PaperTheme.inkTertiary)
            }

            Divider().opacity(0.5)

            Toggle("Follow along (auto-scroll)", isOn: autoScrollBinding)
                .font(.system(size: 12, weight: .medium))
                .tint(PaperTheme.accent)
            Text(presets.activePreset.effectiveTTSAutoScrollEnabled
                 ? "The page scrolls to keep the spoken text in view."
                 : "Scrolling is independent — the page won't jump while it reads.")
                .font(.system(size: 10))
                .foregroundStyle(PaperTheme.inkTertiary)
        }
    }

    private var highlightModeBinding: Binding<TTSHighlightMode> {
        Binding(
            get: { presets.activePreset.effectiveTTSHighlightMode },
            set: { newValue in presets.updateActive { $0.ttsHighlightMode = newValue } }
        )
    }

    private var highlightWindowBinding: Binding<Int> {
        Binding(
            get: { presets.activePreset.effectiveTTSHighlightWindowSize },
            set: { newValue in presets.updateActive { $0.ttsHighlightWindowSize = newValue } }
        )
    }

    private var autoScrollBinding: Binding<Bool> {
        Binding(
            get: { presets.activePreset.effectiveTTSAutoScrollEnabled },
            set: { newValue in presets.updateActive { $0.ttsAutoScrollEnabled = newValue } }
        )
    }
}
