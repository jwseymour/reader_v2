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
        if let goToPage, let page = view.document?.page(at: goToPage) {
            view.go(to: page)
        }
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
    var scrollToPage: Int? = nil
    var onVisiblePage: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let uc = config.userContentController
        uc.add(context.coordinator, name: "pageVisible")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.onVisiblePage = onVisiblePage
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onVisiblePage = onVisiblePage
        let styled = Self.wrap(html: html, preset: preset, highlight: highlightSentence)
        if context.coordinator.lastHTML != styled {
            context.coordinator.lastHTML = styled
            context.coordinator.pendingScrollPage = scrollToPage
            view.loadHTMLString(styled, baseURL: baseURL ?? Bundle.main.resourceURL)
        } else if let scrollToPage {
            if context.coordinator.lastScrolledPage != scrollToPage {
                context.coordinator.scroll(to: scrollToPage, in: view)
            }
        } else {
            context.coordinator.lastScrolledPage = nil
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "pageVisible")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML: String = ""
        var pendingScrollPage: Int?
        var lastScrolledPage: Int?
        var onVisiblePage: ((Int) -> Void)?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pageVisible",
                  let page = message.body as? Int else { return }
            DispatchQueue.main.async { self.onVisiblePage?(page) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let page = pendingScrollPage {
                scroll(to: page, in: webView)
                pendingScrollPage = nil
            }
        }

        func scroll(to page: Int, in webView: WKWebView) {
            lastScrolledPage = page
            webView.evaluateJavaScript(
                "document.getElementById('page-\(page)')?.scrollIntoView({block:'start', behavior:'smooth'});",
                completionHandler: nil
            )
        }
    }

    static func wrap(html: String, preset: ReadingPreset, highlight: String?) -> String {
        let bg = preset.backgroundColorHex
        let fg = preset.textColorHex
        let fontCSSName: String = {
            if preset.fontFamily.hasPrefix(".") { return "-apple-system, BlinkMacSystemFont, sans-serif" }
            if preset.fontFamily.localizedCaseInsensitiveContains("opendyslexic") {
                return "'OpenDyslexic', Georgia, serif"
            }
            return "'\(preset.fontFamily)', Georgia, serif"
        }()
        let size = ReaderFont.displaySize(for: preset)
        let lh = 1.45 + (preset.lineSpacing / 18.0)
        let tracking = preset.characterSpacing
        let word = preset.wordSpacing
        let width = Int(preset.readingWidth)
        let margin = Int(preset.margins)
        let face = ReaderFont.openDyslexicFaceCSS()

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

        let pageObserver = """
        <script>
        document.addEventListener('DOMContentLoaded', () => {
          const sections = Array.from(document.querySelectorAll('section.page'));
          if (!sections.length || !window.webkit?.messageHandlers?.pageVisible) return;
          const io = new IntersectionObserver((entries) => {
            let best = null;
            for (const e of entries) {
              if (!e.isIntersecting) continue;
              if (!best || e.intersectionRatio > best.intersectionRatio) best = e;
            }
            if (best) {
              const idx = parseInt(best.target.getAttribute('data-page') || '0', 10);
              window.webkit.messageHandlers.pageVisible.postMessage(idx);
            }
          }, { root: null, threshold: [0.15, 0.35, 0.55] });
          sections.forEach(s => io.observe(s));
        });
        </script>
        """

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          \(face)
          html, body { background: \(bg); color: \(fg); margin: 0; }
          body {
            font-family: \(fontCSSName);
            font-size: \(String(format: "%.1f", size))px;
            line-height: \(lh);
            letter-spacing: \(tracking)px;
            word-spacing: \(word)px;
            max-width: \(width)px;
            margin: \(margin)px auto;
            padding: 0 16px 64px;
            overflow-wrap: anywhere;
            word-break: break-word;
          }
          section.page { padding-top: 8px; margin-bottom: 36px; }
          .page-label {
            font-size: 10px;
            font-weight: 650;
            letter-spacing: 0.8px;
            color: \(fg)99;
            text-transform: uppercase;
            display: flex;
            align-items: center;
            gap: 8px;
            margin: 28px 0 14px;
          }
          .page-label::after {
            content: "";
            flex: 1;
            height: 1px;
            background: \(fg)22;
          }
          h1, h2, h3 {
            font-family: \(fontCSSName);
            line-height: 1.3;
            letter-spacing: \(tracking)px;
            margin: 1.25em 0 0.55em;
            font-weight: 700;
            overflow-wrap: anywhere;
          }
          h1 { font-size: 1.45em; }
          h2 { font-size: 1.25em; }
          h3 { font-size: 1.1em; }
          p { margin: 0 0 \(max(8, preset.paragraphSpacing))px 0; }
          p.indent-1 { margin-left: 1.5em; }
          p.indent-2 { margin-left: 3em; }
          p.indent-3 { margin-left: 4.5em; }
          p.indent-4 { margin-left: 6em; }
          p.list-item { padding-left: 0.25em; }
          strong { font-weight: 700; }
          em { font-style: italic; }
          u { text-decoration: underline; text-underline-offset: 2px; }
          s { text-decoration: line-through; }
          sub { font-size: 0.75em; }
          sup { font-size: 0.75em; }
          img, svg { max-width: 100%; height: auto; }
        </style></head><body>\(html)\(highlightCSS)\(pageObserver)</body></html>
        """
    }
}

// MARK: - Extracted / reflow text (one continuous scroll document)

struct ExtractedTextView: View {
    let pages: [ExtractedPage]
    var preset: ReadingPreset
    @Binding var currentPage: Int
    var highlightSentence: String
    @Binding var selectedText: String
    var goToPage: Int? = nil

    private var combinedHTML: String {
        pages.map { page in
            """
            <section class="page" id="page-\(page.pageIndex)" data-page="\(page.pageIndex)">
              <div class="page-label">Page \(page.pageIndex + 1)</div>
              \(page.html)
            </section>
            """
        }.joined(separator: "\n")
    }

    var body: some View {
        WebContentView(
            html: combinedHTML.isEmpty ? "<p></p>" : combinedHTML,
            baseURL: Bundle.main.resourceURL,
            preset: preset,
            highlightSentence: highlightSentence.isEmpty ? nil : highlightSentence,
            scrollToPage: goToPage,
            onVisiblePage: { page in
                if currentPage != page { currentPage = page }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(preset.backgroundColor)
        .contextMenu {
            Button("Speak Selection") {
                if let sel = NSPasteboard.general.string(forType: .string) {
                    selectedText = sel
                }
            }
        }
    }
}
