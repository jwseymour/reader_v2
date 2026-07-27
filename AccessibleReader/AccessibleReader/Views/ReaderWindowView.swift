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

    @State private var showInspector = false
    @State private var showOriginalPDF = false
    @State private var showTOC = false
    @State private var showThumbnails = false
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var currentPage = 0
    @State private var selectedText = ""
    @State private var focusY: CGFloat = 0
    @State private var extractedPages: [ExtractedPage] = []
    @State private var extractionFailed = false
    @State private var epub: EPUBContent?
    @State private var epubChapter = 0
    @State private var htmlString: String = ""
    @State private var htmlBase: URL?
    @State private var compareMode: CompareMode = .off
    @State private var abIsB = false
    @State private var showPalette = false
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
                readingSurface(preset: bPreset)
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
                CommandPaletteView(isPresented: $showPalette, actions: paletteActions)
            }
        }
        .toolbar { toolbarContent }
        .onAppear(perform: bootstrap)
        .onChange(of: displayPreset.ttsSpeed) { _, v in tts.speed = v }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTTS)) { _ in
            toggleTTS()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rewindTTS)) { _ in
            tts.rewindTenSeconds()
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
        .background(KeyCaptureView { key in
            handleKey(key)
        })
        .focusable()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4"), .init("5"),
                           .init("6"), .init("7"), .init("8"), .init("9")]) { press in
            if let n = Int(press.characters) {
                presets.activateSlot(n)
                return .handled
            }
            return .ignored
        }
    }

    private var mainReadingColumn: some View {
        VStack(spacing: 0) {
            topChrome
            ZStack {
                readingSurface(preset: displayPreset)
                ReadingAidsOverlay(preset: displayPreset, focusY: $focusY)
                    .allowsHitTesting(displayPreset.rulerEnabled)
            }
            .saturation(1 + displayPreset.saturation)
            .brightness(displayPreset.brightness)
            .contrast(1 + displayPreset.contrast)
            bottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                currentPage = max(0, currentPage - 1)
                jumpPage = currentPage
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
                let maxP = maxPageIndex
                currentPage = min(maxP, currentPage + 1)
                jumpPage = currentPage
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
                    goToPage: jumpPage
                )
                .onChange(of: jumpPage) { _, _ in jumpPage = nil }
            } else {
                ExtractedTextView(
                    pages: extractedPages,
                    preset: preset,
                    currentPage: $currentPage,
                    highlightSentence: tts.currentSentence,
                    selectedText: $selectedText,
                    goToPage: jumpPage
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
                    highlightSentence: tts.currentSentence
                )
            } else {
                ContentUnavailableView("Could not load EPUB", systemImage: "book.closed")
            }
        case .html:
            WebContentView(
                html: htmlString,
                baseURL: htmlBase ?? fileURL?.deletingLastPathComponent(),
                preset: preset,
                highlightSentence: tts.currentSentence
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
            Button("Find") { find(searchQuery) }
                .buttonStyle(.borderedProminent)
                .tint(PaperTheme.accent)
                .controlSize(.small)
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

    private var paletteActions: [(title: String, action: () -> Void)] {
        [
            ("Toggle Reading Lab", { withAnimation { showInspector.toggle() } }),
            ("Toggle Overlay", { presets.updateActive { $0.overlayEnabled.toggle() } }),
            ("Toggle Ruler", { presets.updateActive { $0.rulerEnabled.toggle() } }),
            ("Toggle Line Focus", { presets.updateActive { $0.lineFocusEnabled.toggle() } }),
            ("Toggle Dim Surround", { presets.updateActive { $0.dimSurroundEnabled.toggle() } }),
            ("Toggle Page Focus", { presets.updateActive { $0.pageFocusEnabled.toggle() } }),
            ("Toggle Original PDF", { showOriginalPDF.toggle() }),
            ("Play / Pause Speech", { toggleTTS() }),
            ("Rewind Speech 10s", { tts.rewindTenSeconds() }),
            ("Speech Faster", { tts.adjustSpeed(0.1); presets.updateActive { $0.ttsSpeed = tts.speed } }),
            ("Speech Slower", { tts.adjustSpeed(-0.1); presets.updateActive { $0.ttsSpeed = tts.speed } }),
            ("Search", { showSearch = true }),
            ("A/B Compare Toggle", { abIsB.toggle() }),
            ("Side-by-Side Compare", { compareMode = compareMode == .sideBySide ? .off : .sideBySide }),
            ("Set Compare Preset B = Active", { settings.comparePresetBID = presets.activePresetID }),
            ("Export Active Preset", { exportActivePreset() }),
            ("Import Preset…", { importPreset() })
        ]
    }

    private func bootstrap() {
        if let preferred = settings.preferredPresetID {
            presets.activate(preferred)
        }
        if let voice = DotEnv.value("OPENAI_TTS_VOICE"), !voice.isEmpty {
            presets.updateActive { $0.openAIVoice = voice }
        }
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
        let selection = liveSelectedText()
        if tts.isPlaying {
            tts.pause()
        } else {
            tts.playFromSelection(selection.isEmpty ? nil : selection, currentPage: currentPage)
        }
    }

    private func liveSelectedText() -> String {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            let str = tv.string as NSString
            if let range = tv.selectedRanges.first as? NSRange, range.length > 0 {
                return str.substring(with: range)
            }
        }
        return selectedText
    }

    private func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty || flags == .shift else { return }
        switch event.charactersIgnoringModifiers {
        case "=":
            presets.updateActive { $0.overlayOpacity = min(0.85, $0.overlayOpacity + 0.05) }
        case "-":
            presets.updateActive { $0.overlayOpacity = max(0, $0.overlayOpacity - 0.05) }
        case "j":
            focusY += 20
        case "k":
            focusY = max(20, focusY - 20)
        default:
            break
        }
    }

    private func find(_ query: String) {
        guard !query.isEmpty else { return }
        if kind == .pdf, !showOriginalPDF {
            if let page = extractedPages.first(where: { $0.text.localizedCaseInsensitiveContains(query) }) {
                currentPage = page.pageIndex
                jumpPage = page.pageIndex
            }
        }
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
