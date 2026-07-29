import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AppKit

struct ReaderWindowView: View {
    @Binding var document: ReaderDocument
    var fileURL: URL?

    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var tts = TTSController()
    @StateObject private var selection = ReaderSelection()

    @State private var showInspector = false
    @State private var showOriginalPDF = false
    @State private var showTOC = false
    @State private var showThumbnails = false
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var search = SearchCommand()
    @State private var fitMode: PDFFitMode = .manual
    @State private var window: NSWindow?
    @FocusState private var searchFocused: Bool
    @State private var currentPage = 0
    @State private var focusY: CGFloat = 0
    @State private var focusYB: CGFloat = 0
    @State private var extractedPages: [ExtractedPage] = []
    @State private var extractionFailed = false
    @State private var epub: EPUBContent?
    @State private var epubChapter = 0
    @State private var htmlString: String = ""
    @State private var htmlBase: URL?
    @State private var compareMode: CompareMode = .off
    @State private var abIsB = false
    @State private var showPalette = false
    @State private var showShortcutsGuide = false
    @State private var jumpPage: Int?

    enum CompareMode { case off, sideBySide }

    private var kind: DocumentKind { document.kind }
    private var displayPreset: ReadingPreset {
        if compareMode == .off, abIsB, let bid = settings.comparePresetBID,
           let b = presets.presets.first(where: { $0.id == bid }) {
            return b
        }
        return presets.activePreset
    }

    var body: some View {
        HStack(spacing: 0) {
            if showTOC {
                sidePanel(title: "Contents") { tocPanel }
                    .frame(width: 220)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if showThumbnails && kind == .pdf {
                sidePanel(title: "Pages") { thumbnailPanel }
                    .frame(width: 148)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            mainReadingColumn

            if compareMode == .sideBySide, let bid = settings.comparePresetBID,
               let bPreset = presets.presets.first(where: { $0.id == bid }) {
                Rectangle().fill(PaperTheme.strokeStrong).frame(width: 1)
                // Pane B gets the full aid stack too — comparing overlays and focus
                // combinations is the whole point of side-by-side.
                surfaceWithAids(preset: bPreset, focus: $focusYB)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showInspector {
                Rectangle().fill(PaperTheme.strokeStrong).frame(width: 1)
                InspectorPanel(
                    presets: presets,
                    settings: settings,
                    showOriginalPDF: $showOriginalPDF,
                    kind: kind
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(displayPreset.backgroundColor.opacity(0.55).ignoresSafeArea())
        .preferredColorScheme(.light)
        .toolbarBackground(PaperTheme.elevated, for: .windowToolbar)
        .toolbarColorScheme(.light, for: .windowToolbar)
        .overlay(alignment: .top) {
            if showSearch {
                searchBar
                    .padding(.top, 10)
            }
        }
        .overlay {
            if showPalette {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { showPalette = false }
                CommandPaletteView(isPresented: $showPalette, items: paletteItems)
            }
        }
        .toolbar { toolbarContent }
        .onAppear(perform: bootstrap)
        .onChange(of: displayPreset.ttsSpeed) { _, v in tts.speed = v }
        .onReceive(NotificationCenter.default.publisher(for: .readerCommand)) { note in
            guard let command = note.object as? ReaderCommand else { return }
            // Menu commands broadcast to every window; only the focused paper acts.
            guard window == nil || window?.isKeyWindow == true else { return }
            handle(command)
        }
        .onChange(of: showOriginalPDF) { _, _ in
            preserveReadingPosition()
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasCompletedFirstRun },
            set: { _ in }
        )) {
            FirstRunView(presets: presets, settings: settings)
        }
        .sheet(isPresented: $showShortcutsGuide) {
            ShortcutsGuideView()
        }
        .background(KeyCaptureView(onEvent: { event in
            handleKeyEvent(event)
        }, onWindow: { w in
            window = w
        }))
    }

    private var mainReadingColumn: some View {
        VStack(spacing: 0) {
            topChrome
            surfaceWithAids(preset: displayPreset, focus: $focusY)
            bottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A reading surface with the full combinable aid stack on top of it.
    private func surfaceWithAids(preset: ReadingPreset, focus: Binding<CGFloat>) -> some View {
        ZStack {
            readingSurface(preset: preset)
            ReadingAidsOverlay(preset: preset, focusY: focus)
                .allowsHitTesting(preset.rulerEnabled)
        }
        .saturation(1 + preset.saturation)
        .brightness(preset.brightness)
        .contrast(1 + preset.contrast)
    }

    // MARK: - Chrome

    private var topChrome: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL?.deletingPathExtension().lastPathComponent ?? "Document")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(PaperTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(PaperTheme.accentSoft)
                        .foregroundStyle(PaperTheme.accent)
                        .clipShape(Capsule())
                    Text(displayPreset.name)
                        .font(.system(size: 11))
                        .foregroundStyle(PaperTheme.inkSecondary)
                    if abIsB {
                        Text("Comparing B")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PaperTheme.warning)
                    }
                }
            }

            Spacer()

            if kind == .pdf {
                pageIndicator
            }

            if tts.isPlaying {
                HStack(spacing: 4) {
                    Circle()
                        .fill(PaperTheme.accent)
                        .frame(width: 6, height: 6)
                    Text("Speaking")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(PaperTheme.accent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(PaperTheme.accentSoft)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PaperTheme.elevated.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle().fill(PaperTheme.stroke).frame(height: 1)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            Button {
                goToPage(currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PaperTheme.inkSecondary)
            .disabled(currentPage <= 0)

            Text("Page \(currentPage + 1)\(pageCountText)")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(PaperTheme.ink)

            Button {
                goToPage(currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PaperTheme.inkSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(PaperTheme.mist)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(PaperTheme.stroke, lineWidth: 1))
    }

    private var maxPageIndex: Int {
        if !extractedPages.isEmpty { return max(0, extractedPages.count - 1) }
        if let doc = PDFDocument(data: document.data) { return max(0, doc.pageCount - 1) }
        return 0
    }

    private var kindLabel: String {
        switch kind {
        case .pdf: return showOriginalPDF ? "PDF" : "Reflow"
        case .epub: return "EPUB"
        case .html: return "HTML"
        }
    }

    private var bottomChrome: some View {
        HStack(spacing: 10) {
            // TTS cluster
            HStack(spacing: 4) {
                chromeIconButton(
                    systemName: tts.isPlaying ? "pause.fill" : "play.fill",
                    help: "Play / pause speech",
                    prominent: true
                ) { toggleTTS() }
                chromeIconButton(systemName: "gobackward.10", help: "Rewind ~10s") {
                    tts.rewindTenSeconds()
                }
                Text(String(format: "%.1f×", tts.speed))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(PaperTheme.inkSecondary)
                    .frame(width: 36)
            }

            thinDivider

            // Focus quick toggles
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ChromePill(
                        title: "Overlay",
                        systemImage: "circle.lefthalf.filled",
                        active: displayPreset.overlayEnabled
                    ) {
                        presets.updateActive { $0.overlayEnabled.toggle() }
                    }
                    ChromePill(
                        title: "Dim",
                        systemImage: "rectangle.bottomhalf.filled",
                        active: displayPreset.dimSurroundEnabled
                    ) {
                        presets.updateActive { $0.dimSurroundEnabled.toggle() }
                    }
                    ChromePill(
                        title: "Lines",
                        systemImage: "text.alignleft",
                        active: displayPreset.lineFocusEnabled
                    ) {
                        presets.updateActive { $0.lineFocusEnabled.toggle() }
                    }
                    ChromePill(
                        title: "Ruler",
                        systemImage: "ruler",
                        active: displayPreset.rulerEnabled
                    ) {
                        presets.updateActive { $0.rulerEnabled.toggle() }
                    }
                }
            }

            Spacer(minLength: 8)

            if kind == .pdf {
                ChromePill(
                    title: showOriginalPDF ? "Original" : "Reflow",
                    systemImage: showOriginalPDF ? "doc.richtext" : "doc.plaintext",
                    active: false
                ) {
                    showOriginalPDF.toggle()
                }
            }

            ChromePill(title: "Lab", systemImage: "slider.horizontal.3", active: showInspector) {
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PaperTheme.elevated.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle().fill(PaperTheme.stroke).frame(height: 1)
        }
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(PaperTheme.strokeStrong)
            .frame(width: 1, height: 22)
    }

    private func chromeIconButton(systemName: String, help: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : PaperTheme.ink)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(prominent ? PaperTheme.accent : PaperTheme.mist)
                )
                .overlay(
                    Circle().strokeBorder(prominent ? Color.clear : PaperTheme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func sidePanel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(PaperTheme.inkSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(PaperTheme.stroke).frame(height: 1)
            }
            content()
        }
        .background(PaperTheme.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(PaperTheme.strokeStrong).frame(width: 1)
        }
    }

    // MARK: - Surfaces

    @ViewBuilder
    private func readingSurface(preset: ReadingPreset) -> some View {
        switch kind {
        case .pdf:
            if showOriginalPDF || extractionFailed {
                PDFVisualView(
                    data: document.data,
                    preset: preset,
                    currentPage: $currentPage,
                    goToPage: jumpPage,
                    selection: selection,
                    search: search,
                    fitMode: fitMode
                )
                .onChange(of: jumpPage) { _, _ in jumpPage = nil }
            } else {
                ExtractedTextView(
                    pages: extractedPages,
                    preset: preset,
                    currentPage: $currentPage,
                    highlightSentence: tts.currentHighlight,
                    selection: selection,
                    goToPage: jumpPage,
                    search: search
                )
                .onChange(of: jumpPage) { _, _ in jumpPage = nil }
            }
        case .epub:
            if let epub, epub.spineHTMLs.indices.contains(epubChapter) {
                let ch = epub.spineHTMLs[epubChapter]
                WebContentView(
                    html: ch.html,
                    baseURL: ch.baseURL,
                    preset: preset,
                    highlightSentence: tts.currentHighlight,
                    selection: selection,
                    search: search
                )
            } else {
                ContentUnavailableView("Could not load EPUB", systemImage: "book.closed")
            }
        case .html:
            WebContentView(
                html: htmlString,
                baseURL: htmlBase ?? fileURL?.deletingLastPathComponent(),
                preset: preset,
                highlightSentence: tts.currentHighlight,
                selection: selection,
                search: search
            )
        }
    }

    private var pageCountText: String {
        if !extractedPages.isEmpty { return " / \(extractedPages.count)" }
        if let doc = PDFDocument(data: document.data) { return " / \(doc.pageCount)" }
        return ""
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PaperTheme.inkTertiary)
            TextField("Find in document", text: $searchQuery)
                .textFieldStyle(.plain)
                .frame(maxWidth: 320)
                .focused($searchFocused)
                .onSubmit { find(searchQuery, forward: true) }
            Button {
                find(searchQuery, forward: false)
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Previous match (⌘⇧G)")
            Button {
                find(searchQuery, forward: true)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Next match (⌘G)")
            Button("Done") { showSearch = false }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PaperTheme.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var tocPanel: some View {
        List {
            if kind == .epub, let epub {
                ForEach(epub.toc, id: \.index) { item in
                    Button(item.title) { epubChapter = item.index }
                        .foregroundStyle(PaperTheme.ink)
                }
            } else if kind == .pdf {
                ForEach(extractedPages) { page in
                    Button("Page \(page.pageIndex + 1)") {
                        currentPage = page.pageIndex
                        jumpPage = page.pageIndex
                    }
                    .foregroundStyle(page.pageIndex == currentPage ? PaperTheme.accent : PaperTheme.ink)
                }
            } else {
                Text("No contents").foregroundStyle(PaperTheme.inkTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private var thumbnailPanel: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let doc = PDFDocument(data: document.data) {
                    ForEach(0..<doc.pageCount, id: \.self) { i in
                        if let page = doc.page(at: i) {
                            Button {
                                currentPage = i
                                jumpPage = i
                                if !showOriginalPDF { showOriginalPDF = true }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: page.thumbnail(of: CGSize(width: 100, height: 140), for: .mediaBox))
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(i == currentPage ? PaperTheme.accent : PaperTheme.stroke, lineWidth: i == currentPage ? 2 : 1)
                                        )
                                    Text("\(i + 1)")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(PaperTheme.inkTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { withAnimation { showTOC.toggle() } } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .help("Table of contents")
            .foregroundStyle(PaperTheme.ink)
            if kind == .pdf {
                Button { withAnimation { showThumbnails.toggle() } } label: {
                    Label("Thumbnails", systemImage: "rectangle.grid.1x2")
                }
                .help("Page thumbnails")
                .foregroundStyle(PaperTheme.ink)
            }
        }
        ToolbarItemGroup {
            Button { showSearch.toggle() } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .foregroundStyle(PaperTheme.ink)
            Button { abIsB.toggle() } label: {
                Text("A/B")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(PaperTheme.ink)
            }
            .help("Toggle A/B preset compare")
            Button {
                compareMode = compareMode == .sideBySide ? .off : .sideBySide
            } label: {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .help("Side-by-side preset compare")
            .foregroundStyle(PaperTheme.ink)
            Button { showPalette = true } label: {
                Label("Commands", systemImage: "command")
            }
            .help("Command palette")
            .foregroundStyle(PaperTheme.ink)
        }
    }

    /// Every command the palette can run, grouped and sorted to match
    /// `ReaderShortcuts.bindings` — the same table `handleKeyEvent` dispatches
    /// from — so every shown shortcut is one the keyboard actually recognizes,
    /// and the palette can never list an action under a key combo that doesn't
    /// really trigger it. A handful of actions (preset import/export, etc.) have
    /// no keyboard shortcut and are appended after with `shortcut: nil`.
    private var paletteItems: [CommandPaletteItem] {
        var seenLabels = Set<String>()
        var items: [CommandPaletteItem] = []
        for binding in ReaderShortcuts.bindings where !seenLabels.contains(binding.label) {
            seenLabels.insert(binding.label)
            items.append(CommandPaletteItem(
                title: binding.label,
                group: binding.group,
                shortcut: binding.symbol,
                action: { handle(binding.command) }
            ))
        }
        items.append(contentsOf: [
            CommandPaletteItem(title: "Set Compare Preset B = Active", group: "Presets & Compare", shortcut: nil) {
                settings.comparePresetBID = presets.activePresetID
            },
            CommandPaletteItem(title: "Export Active Preset", group: "Presets & Compare", shortcut: nil) {
                exportActivePreset()
            },
            CommandPaletteItem(title: "Import Preset…", group: "Presets & Compare", shortcut: nil) {
                importPreset()
            }
        ])
        return items
    }

    private func bootstrap() {
        if let preferred = settings.preferredPresetID {
            presets.activate(preferred)
        }
        // OPENAI_TTS_VOICE used to be written into the active preset on every open,
        // silently overwriting whatever voice had been chosen in the inspector.
        tts.speed = presets.activePreset.ttsSpeed
        tts.useOpenAI = presets.activePreset.ttsPreferOpenAI

        switch kind {
        case .pdf:
            extractedPages = PDFExtractor.extractPages(from: document.data)
            extractionFailed = !PDFExtractor.extractionLooksViable(extractedPages)
            if extractionFailed { showOriginalPDF = true }
            tts.load(paragraphs: TTSTextSplitter.paragraphs(from: extractedPages))
        case .epub:
            do {
                epub = try EPUBLoader.load(from: document.data)
                let plain = epub?.spineHTMLs.map(\.html)
                    .map { $0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) }
                    .joined(separator: "\n\n") ?? ""
                tts.load(paragraphs: TTSTextSplitter.paragraphs(from: plain))
            } catch {
                epub = nil
            }
        case .html:
            htmlString = String(data: document.data, encoding: .utf8)
                ?? String(data: document.data, encoding: .isoLatin1)
                ?? ""
            htmlBase = fileURL?.deletingLastPathComponent()
            let plain = htmlString.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            tts.load(paragraphs: TTSTextSplitter.paragraphs(from: plain))
        }
    }

    private func preserveReadingPosition() {
        let page = currentPage
        // Clear then re-set so the newly mounted view always receives a jump,
        // even when the page number is unchanged.
        jumpPage = nil
        DispatchQueue.main.async {
            jumpPage = page
        }
    }

    private func toggleTTS() {
        tts.speed = displayPreset.ttsSpeed
        tts.useOpenAI = displayPreset.ttsPreferOpenAI
        tts.togglePlayPause(selection: selection.text, currentPage: currentPage)
    }

    private func handle(_ command: ReaderCommand) {
        switch command {
        case .toggleInspector:
            withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
        case .commandPalette: showPalette = true
        case .toggleTTS: toggleTTS()
        case .rewindTTS: tts.rewindTenSeconds()
        case .speedUp: changeSpeed(0.1)
        case .speedDown: changeSpeed(-0.1)
        case .toggleOverlay: presets.updateActive { $0.overlayEnabled.toggle() }
        case .toggleRuler: presets.updateActive { $0.rulerEnabled.toggle() }
        case .toggleLineFocus: presets.updateActive { $0.lineFocusEnabled.toggle() }
        case .toggleDimSurround: presets.updateActive { $0.dimSurroundEnabled.toggle() }
        case .togglePageFocus: presets.updateActive { $0.pageFocusEnabled.toggle() }
        case .overlayOpacityUp: adjustOverlayOpacity(0.05)
        case .overlayOpacityDown: adjustOverlayOpacity(-0.05)
        case .zoomIn: setZoom(displayPreset.zoomPercent + 10)
        case .zoomOut: setZoom(displayPreset.zoomPercent - 10)
        case .zoomReset: setZoom(100)
        case .fitWidth: fitMode = .fitWidth
        case .fitPage: fitMode = .fitPage
        case .toggleTOC: withAnimation { showTOC.toggle() }
        case .toggleThumbnails: withAnimation { showThumbnails.toggle() }
        case .toggleOriginalPDF: if kind == .pdf { showOriginalPDF.toggle() }
        case .find:
            showSearch = true
            searchFocused = true
        case .findNext: find(searchQuery, forward: true)
        case .findPrevious: find(searchQuery, forward: false)
        case .nextPage: goToPage(currentPage + 1)
        case .previousPage: goToPage(currentPage - 1)
        case .toggleAB: abIsB.toggle()
        case .toggleSideBySide:
            compareMode = compareMode == .sideBySide ? .off : .sideBySide
        case .rulerNudgeUp: focusY = max(20, focusY - 20)
        case .rulerNudgeDown: focusY += 20
        case .toggleShortcutsGuide: showShortcutsGuide = true
        }
    }

    private func changeSpeed(_ delta: Double) {
        tts.adjustSpeed(delta)
        presets.updateActive { $0.ttsSpeed = tts.speed }
    }

    private func adjustOverlayOpacity(_ delta: Double) {
        presets.updateActive {
            $0.overlayOpacity = min(0.85, max(0, $0.overlayOpacity + delta))
            if delta > 0 { $0.overlayEnabled = true }
        }
    }

    private func setZoom(_ percent: Double) {
        fitMode = .manual
        presets.updateActive { $0.zoomPercent = min(250, max(50, percent)) }
    }

    private func goToPage(_ page: Int) {
        let clamped = min(maxPageIndex, max(0, page))
        currentPage = clamped
        jumpPage = clamped
    }

    /// The single entry point for every keyboard shortcut in the app. Runs inside
    /// `KeyCaptureView`'s pre-dispatch event monitor, so it fires reliably no
    /// matter which subview (`WKWebView`, `PDFView`) currently has focus.
    /// Returns `true` when the event was recognized and should be consumed.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty, let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n) {
            presets.activateSlot(n)
            return true
        }
        if flags == .command, let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n) {
            presets.activateSlot(n)
            return true
        }
        guard let binding = ReaderShortcuts.match(event) else { return false }
        handle(binding.command)
        return true
    }

    /// Search runs inside the reading surface itself, so it works for the extracted
    /// text, the visual PDF, EPUB and HTML alike, with next/previous and wrapping.
    private func find(_ query: String, forward: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !showSearch { showSearch = true }
        search = SearchCommand(query: trimmed, forward: forward, counter: search.counter + 1)
    }

    private func exportActivePreset() {
        guard let data = presets.exportPreset(presets.activePreset.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(presets.activePreset.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            _ = try? presets.importPreset(from: data)
        }
    }
}
