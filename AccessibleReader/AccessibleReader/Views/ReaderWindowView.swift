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
    @State private var rulerY: CGFloat = 0
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
    @State private var invertActive = false

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
                tocPanel
                    .frame(width: 220)
                    .transition(.move(edge: .leading))
            }
            if showThumbnails && kind == .pdf {
                thumbnailPanel
                    .frame(width: 140)
                    .transition(.move(edge: .leading))
            }

            mainReadingColumn

            if compareMode == .sideBySide, let bid = settings.comparePresetBID,
               let bPreset = presets.presets.first(where: { $0.id == bid }) {
                Divider()
                readingSurface(preset: bPreset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showInspector {
                Divider()
                InspectorPanel(
                    presets: presets,
                    settings: settings,
                    showOriginalPDF: $showOriginalPDF,
                    kind: kind
                )
                .transition(.move(edge: .trailing))
            }
        }
        .background(PaperTheme.chrome(for: displayPreset).ignoresSafeArea())
        .overlay(alignment: .top) {
            if showSearch {
                searchBar
                    .padding(.top, 8)
            }
        }
        .overlay {
            if showPalette {
                Color.black.opacity(0.2).ignoresSafeArea()
                    .onTapGesture { showPalette = false }
                CommandPaletteView(isPresented: $showPalette, actions: paletteActions)
            }
        }
        .toolbar { toolbarContent }
        .onAppear(perform: bootstrap)
        .onChange(of: displayPreset.ttsSpeed) { _, v in tts.speed = v }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            withAnimation { showInspector.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTTS)) { _ in
            toggleTTS()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rewindTTS)) { _ in
            tts.rewindTenSeconds()
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
            statusBar
            ZStack {
                readingSurface(preset: displayPreset)
                ReadingAidsOverlay(preset: displayPreset, rulerY: $rulerY)
                    .allowsHitTesting(displayPreset.rulerEnabled)
            }
            .colorMultiply(displayPreset.invertColors ? Color.white : Color.white)
            .saturation(1 + displayPreset.saturation)
            .brightness(displayPreset.brightness)
            .contrast(1 + displayPreset.contrast)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
                    selectedText: $selectedText
                )
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

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("AccessibleReaderV2")
                .font(.caption.weight(.bold))
                .foregroundStyle(PaperTheme.accent)
            Text(fileURL?.lastPathComponent ?? "Document")
                .font(.caption.weight(.medium))
                .foregroundStyle(PaperTheme.ink.opacity(0.7))
                .lineLimit(1)
            Spacer()
            if kind == .pdf {
                Text("Page \(currentPage + 1)\(pageCountText)")
                    .font(.caption)
                    .monospacedDigit()
            }
            if tts.isPlaying {
                Text("TTS")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PaperTheme.accent.opacity(0.2))
                    .clipShape(Capsule())
            }
            if abIsB { Text("Preset B").font(.caption2).foregroundStyle(PaperTheme.accent) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(displayPreset.backgroundColor.opacity(0.85))
    }

    private var pageCountText: String {
        if !extractedPages.isEmpty { return " / \(extractedPages.count)" }
        if let doc = PDFDocument(data: document.data) { return " / \(doc.pageCount)" }
        return ""
    }

    private var searchBar: some View {
        HStack {
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Button("Find") { find(searchQuery) }
            Button("Done") { showSearch = false }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tocPanel: some View {
        List {
            if kind == .epub, let epub {
                ForEach(epub.toc, id: \.index) { item in
                    Button(item.title) { epubChapter = item.index }
                }
            } else if kind == .pdf {
                ForEach(extractedPages) { page in
                    Button("Page \(page.pageIndex + 1)") {
                        currentPage = page.pageIndex
                        jumpPage = page.pageIndex
                    }
                }
            } else {
                Text("No TOC").foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paperDark.opacity(0.9))
    }

    private var thumbnailPanel: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if let doc = PDFDocument(data: document.data) {
                    ForEach(0..<doc.pageCount, id: \.self) { i in
                        if let page = doc.page(at: i) {
                            Button {
                                currentPage = i
                                jumpPage = i
                                if !showOriginalPDF { showOriginalPDF = true }
                            } label: {
                                Image(nsImage: page.thumbnail(of: CGSize(width: 100, height: 140), for: .mediaBox))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 100)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(i == currentPage ? PaperTheme.accent : .clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(PaperTheme.paperDark.opacity(0.9))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showTOC.toggle() } label: { Image(systemName: "list.bullet") }
                .help("Table of contents")
            if kind == .pdf {
                Button { showThumbnails.toggle() } label: { Image(systemName: "rectangle.grid.1x2") }
                    .help("Thumbnails")
            }
        }
        ToolbarItemGroup {
            Button { showSearch.toggle() } label: { Image(systemName: "magnifyingglass") }
            if kind == .pdf {
                Button {
                    showOriginalPDF.toggle()
                } label: {
                    Image(systemName: showOriginalPDF ? "doc.plaintext" : "doc.richtext")
                }
                .help(showOriginalPDF ? "Show extracted text" : "Show original PDF")
            }
            Button { toggleTTS() } label: {
                Image(systemName: tts.isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Play / pause TTS")
            Button { tts.rewindTenSeconds() } label: { Image(systemName: "gobackward.10") }
            Button { abIsB.toggle() } label: { Text("A/B") }
                .help("Toggle A/B preset compare")
            Button {
                compareMode = compareMode == .sideBySide ? .off : .sideBySide
            } label: { Image(systemName: "rectangle.split.2x1") }
            .help("Side-by-side preset compare")
            Button { showPalette = true } label: { Image(systemName: "command") }
            Button { withAnimation { showInspector.toggle() } } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle inspector")
        }
    }

    private var paletteActions: [(title: String, action: () -> Void)] {
        [
            ("Toggle Inspector", { showInspector.toggle() }),
            ("Toggle Overlay", { presets.updateActive { $0.overlayEnabled.toggle() } }),
            ("Toggle Ruler", { presets.updateActive { $0.rulerEnabled.toggle() } }),
            ("Toggle Line Focus", { presets.updateActive { $0.lineFocusEnabled.toggle() } }),
            ("Toggle Dim Surround", { presets.updateActive { $0.dimSurroundEnabled.toggle() } }),
            ("Toggle Page Focus", { presets.updateActive { $0.pageFocusEnabled.toggle() } }),
            ("Toggle Original PDF", { showOriginalPDF.toggle() }),
            ("Play / Pause TTS", { toggleTTS() }),
            ("Rewind TTS 10s", { tts.rewindTenSeconds() }),
            ("TTS Faster", { tts.adjustSpeed(0.1); presets.updateActive { $0.ttsSpeed = tts.speed } }),
            ("TTS Slower", { tts.adjustSpeed(-0.1); presets.updateActive { $0.ttsSpeed = tts.speed } }),
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
            rulerY += 20
        case "k":
            rulerY = max(20, rulerY - 20)
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
