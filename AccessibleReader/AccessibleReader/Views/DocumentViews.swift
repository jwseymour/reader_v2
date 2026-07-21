import SwiftUI
import PDFKit
import WebKit
import AppKit
import UniformTypeIdentifiers

// MARK: - PDF Visual

struct PDFVisualView: NSViewRepresentable {
    let data: Data
    var preset: ReadingPreset
    @Binding var currentPage: Int
    var goToPage: Int?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = preset.continuousScroll ? .singlePageContinuous : .singlePage
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        view.delegate = context.coordinator
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: view
        )
        apply(preset, to: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document == nil {
            view.document = PDFDocument(data: data)
        }
        view.displayMode = preset.continuousScroll ? .singlePageContinuous : .singlePage
        apply(preset, to: view)
        if let goToPage, let page = view.document?.page(at: goToPage) {
            view.go(to: page)
        }
    }

    private func apply(_ preset: ReadingPreset, to view: PDFView) {
        view.scaleFactor = preset.zoomPercent / 100.0
        // Colour filters approximated via background
        view.backgroundColor = NSColor(preset.backgroundColor)
    }

    func makeCoordinator() -> Coordinator { Coordinator(currentPage: $currentPage) }

    final class Coordinator: NSObject, PDFViewDelegate {
        @Binding var currentPage: Int
        init(currentPage: Binding<Int>) { _currentPage = currentPage }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView,
                  let page = view.currentPage,
                  let doc = view.document else { return }
            currentPage = doc.index(for: page)
        }
    }
}

// MARK: - Web content (HTML / EPUB chapter)

struct WebContentView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    var preset: ReadingPreset
    var highlightSentence: String?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let styled = Self.wrap(html: html, preset: preset, highlight: highlightSentence)
        if context.coordinator.lastHTML != styled {
            context.coordinator.lastHTML = styled
            view.loadHTMLString(styled, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML: String = "" }

    static func wrap(html: String, preset: ReadingPreset, highlight: String?) -> String {
        let bg = preset.backgroundColorHex
        let fg = preset.textColorHex
        let font = preset.fontFamily
        let size = preset.fontSize
        let lh = 1.35 + (preset.lineSpacing / 20.0)
        let tracking = preset.characterSpacing
        let word = preset.wordSpacing
        let width = Int(preset.readingWidth)
        let margin = Int(preset.margins)
        var highlightCSS = ""
        if let highlight, !highlight.isEmpty {
            let escaped = highlight
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            highlightCSS = """
            <script>
            document.addEventListener('DOMContentLoaded', () => {
              const needle = '\(escaped)';
              const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
              let node;
              while (node = walk.nextNode()) {
                const i = node.nodeValue.indexOf(needle);
                if (i >= 0) {
                  const range = document.createRange();
                  range.setStart(node, i);
                  range.setEnd(node, i + needle.length);
                  const mark = document.createElement('mark');
                  mark.style.background = 'rgba(255, 220, 120, 0.7)';
                  range.surroundContents(mark);
                  mark.scrollIntoView({block:'center', behavior:'smooth'});
                  break;
                }
              }
            });
            </script>
            """
        }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          html, body { background: \(bg); color: \(fg); margin: 0; }
          body {
            font-family: '\(font)', Georgia, serif;
            font-size: \(size)px;
            line-height: \(lh);
            letter-spacing: \(tracking)px;
            word-spacing: \(word)px;
            max-width: \(width)px;
            margin: \(margin)px auto;
            padding: 0 16px;
          }
          p { margin: 0 0 \(preset.paragraphSpacing)px 0; }
          img, svg { max-width: 100%; height: auto; }
        </style></head><body>\(html)\(highlightCSS)</body></html>
        """
    }
}

// MARK: - Extracted text

struct ExtractedTextView: View {
    let pages: [ExtractedPage]
    var preset: ReadingPreset
    @Binding var currentPage: Int
    var highlightSentence: String
    @Binding var selectedText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: preset.paragraphSpacing) {
                    ForEach(pages) { page in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Page \(page.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(PaperTheme.accent.opacity(0.7))
                            pageText(page)
                        }
                        .id(page.pageIndex)
                        .padding(.bottom, 24)
                        .onAppear { currentPage = page.pageIndex }
                    }
                }
                .frame(maxWidth: preset.readingWidth)
                .padding(.horizontal, preset.margins)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: highlightSentence) { _, new in
                guard !new.isEmpty, let page = pages.first(where: { $0.text.contains(new) }) else { return }
                withAnimation { proxy.scrollTo(page.pageIndex, anchor: .center) }
            }
            .onChange(of: currentPage) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .top) }
            }
            .background(preset.backgroundColor)
        }
    }

    @ViewBuilder
    private func pageText(_ page: ExtractedPage) -> some View {
        let highlight = (!highlightSentence.isEmpty && page.text.contains(highlightSentence)) ? highlightSentence : ""
        Text(attributed(page.text, highlight: highlight))
            .textSelection(.enabled)
            .lineSpacing(preset.lineSpacing)
            .tracking(preset.characterSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { _ in
                    // Selection is read via copy; also allow using highlight as selection cue
                }
            )
            .contextMenu {
                Button("Speak Selection") {
                    if let sel = NSPasteboard.general.string(forType: .string) {
                        selectedText = sel
                    }
                }
            }
    }

    private func attributed(_ text: String, highlight: String) -> AttributedString {
        var result = AttributedString(text)
        let fontName = preset.fontFamily.hasPrefix(".") ? nil : preset.fontFamily
        if let fontName, let _ = NSFont(name: fontName, size: preset.fontSize) {
            result.font = Font.custom(fontName, size: preset.fontSize)
        } else {
            result.font = .system(size: preset.fontSize)
        }
        result.foregroundColor = preset.textColor
        if !highlight.isEmpty, let strRange = text.range(of: highlight) {
            if let start = AttributedString.Index(strRange.lowerBound, within: result),
               let end = AttributedString.Index(strRange.upperBound, within: result) {
                result[start..<end].backgroundColor = .yellow.opacity(0.45)
            }
        }
        return result
    }
}
