import SwiftUI
import PDFKit
import WebKit
import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Search

/// A find request. `counter` lets the same query be re-issued for next/previous
/// without the view diffing it away as "unchanged".
struct SearchCommand: Equatable {
    var query: String = ""
    var forward: Bool = true
    var counter: Int = 0
}

/// How the visual PDF is scaled. Window state rather than preset state, so that
/// `presets.json` files written by earlier builds still decode.
enum PDFFitMode {
    case manual
    case fitWidth
    case fitPage
}

// MARK: - Visual layer adjustments

/// Gamma and invert can't be expressed with SwiftUI's built-in modifiers, so they
/// are applied as Core Image filters on the surface's backing layer. This works
/// for both `PDFView` and `WKWebView` because both are ordinary layer-backed views.
enum VisualFilters {
    static func apply(_ preset: ReadingPreset, to view: NSView) {
        var filters: [CIFilter] = []
        if abs(preset.gamma - 1.0) > 0.01, let f = CIFilter(name: "CIGammaAdjust") {
            f.setValue(preset.gamma, forKey: "inputPower")
            filters.append(f)
        }
        if preset.invertColors, let f = CIFilter(name: "CIColorInvert") {
            filters.append(f)
        }
        view.wantsLayer = true
        if filters.isEmpty {
            view.layer?.filters = nil
        } else {
            view.layerUsesCoreImageFilters = true
            view.layer?.filters = filters
        }
    }
}

/// Bumped to request a new highlight be created from the PDF view's current
/// text selection — the same "bump a counter, diff it in updateNSView" idiom
/// as `SearchCommand`.
struct HighlightCommand: Equatable {
    var counter: Int = 0
}

// MARK: - PDF Visual

struct PDFVisualView: NSViewRepresentable {
    let data: Data
    var preset: ReadingPreset
    @Binding var currentPage: Int
    var goToPage: Int?
    var selection: ReaderSelection?
    var search: SearchCommand = SearchCommand()
    var fitMode: PDFFitMode = .manual
    /// Stored highlights for this document, pre-filtered by the caller — this
    /// view never needs to know about document identity or touch any store.
    var annotations: [PDFHighlightAnnotation] = []
    var highlightRequest: HighlightCommand = HighlightCommand()
    var onCreateHighlight: ((Int, String, [CGRect], String?) -> Void)?
    var onEditHighlight: ((PDFHighlightAnnotation) -> Void)?
    var onDeleteHighlight: ((UUID) -> Void)?
    /// The sentence or word window currently being spoken, if TTS is playing —
    /// shown via `PDFView.highlightedSelections`, a transient rendering-only
    /// overlay that's independent of `currentSelection`/stored annotations, so
    /// it can never interfere with manual text selection or highlight creation.
    var ttsHighlightText: String? = nil
    var ttsAutoScroll: Bool = true

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = preset.continuousScroll ? .singlePageContinuous : .singlePage
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        view.delegate = context.coordinator
        context.coordinator.selection = selection
        context.coordinator.onCreateHighlight = onCreateHighlight
        context.coordinator.onEditHighlight = onEditHighlight
        context.coordinator.onDeleteHighlight = onDeleteHighlight
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: Notification.Name.PDFViewSelectionChanged,
            object: view
        )
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        // NSClickGestureRecognizer defaults to delaying primary mouse-button
        // events until it has failed to recognize a click — which, left on,
        // holds back the exact mouseDown/mouseDragged sequence PDFView's own
        // click-and-drag text selection relies on internally. With it on,
        // dragging to select text (what highlight creation depends on) is
        // broken or badly delayed; this opts back out so the recognizer only
        // observes clicks without gating PDFView's native mouse handling.
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        apply(preset, to: view)
        if let goToPage, let page = view.document?.page(at: goToPage) {
            view.go(to: page)
        }
        context.coordinator.lastAnnotations = annotations
        if let doc = view.document { PDFHighlightRendering.apply(annotations, to: doc) }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.selection = selection
        context.coordinator.onCreateHighlight = onCreateHighlight
        context.coordinator.onEditHighlight = onEditHighlight
        context.coordinator.onDeleteHighlight = onDeleteHighlight
        if view.document == nil {
            view.document = PDFDocument(data: data)
        }
        view.displayMode = preset.continuousScroll ? .singlePageContinuous : .singlePage
        apply(preset, to: view)
        if let goToPage, let page = view.document?.page(at: goToPage) {
            view.go(to: page)
        }
        if context.coordinator.lastSearch != search {
            context.coordinator.lastSearch = search
            context.coordinator.runSearch(search, in: view)
        }
        if context.coordinator.lastAnnotations != annotations {
            context.coordinator.lastAnnotations = annotations
            context.coordinator.refreshHighlights(in: view, annotations: annotations)
        }
        if context.coordinator.lastHighlightRequest.counter != highlightRequest.counter {
            context.coordinator.lastHighlightRequest = highlightRequest
            context.coordinator.createHighlightFromSelection(in: view)
        }
        let ttsText = ttsHighlightText ?? ""
        if context.coordinator.lastTTSHighlight != ttsText {
            context.coordinator.lastTTSHighlight = ttsText
            context.coordinator.applyTTSHighlight(ttsHighlightText, autoScroll: ttsAutoScroll, currentPage: currentPage, in: view)
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    private func apply(_ preset: ReadingPreset, to view: PDFView) {
        // autoScales silently overrides scaleFactor, so the old code set a zoom that
        // PDFKit then ignored. Only let it win when a fit mode is actually requested.
        switch fitMode {
        case .manual:
            view.autoScales = false
            view.scaleFactor = preset.zoomPercent / 100.0
        case .fitWidth:
            view.autoScales = true
        case .fitPage:
            view.autoScales = false
            view.scaleFactor = view.scaleFactorForSizeToFit
        }
        view.backgroundColor = NSColor(preset.backgroundColor)
        VisualFilters.apply(preset, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(currentPage: $currentPage) }

    final class Coordinator: NSObject, PDFViewDelegate {
        @Binding var currentPage: Int
        var selection: ReaderSelection?
        var lastSearch = SearchCommand()
        var lastAnnotations: [PDFHighlightAnnotation] = []
        var lastHighlightRequest = HighlightCommand()
        var onCreateHighlight: ((Int, String, [CGRect], String?) -> Void)?
        var onEditHighlight: ((PDFHighlightAnnotation) -> Void)?
        var onDeleteHighlight: ((UUID) -> Void)?
        var lastTTSHighlight: String = ""
        private var editorPopover: NSPopover?
        private var openEditorAnnotationID: UUID?

        init(currentPage: Binding<Int>) { _currentPage = currentPage }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView,
                  let page = view.currentPage,
                  let doc = view.document else { return }
            currentPage = doc.index(for: page)
        }

        @objc func selectionChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            let text = view.currentSelection?.string
            Task { @MainActor in self.selection?.update(text) }
        }

        func runSearch(_ command: SearchCommand, in view: PDFView) {
            guard let doc = view.document, !command.query.isEmpty else { return }
            var options: NSString.CompareOptions = [.caseInsensitive]
            if !command.forward { options.insert(.backwards) }
            let found = doc.findString(command.query, fromSelection: view.currentSelection, withOptions: options)
                ?? doc.findString(command.query, fromSelection: nil, withOptions: options)
            guard let found else { return }
            view.setCurrentSelection(found, animate: true)
            view.go(to: found)
        }

        func refreshHighlights(in view: PDFView, annotations: [PDFHighlightAnnotation]) {
            guard let doc = view.document else { return }
            // A remote edit (synced in via ZoteroSyncStore, e.g. from the streaming
            // socket) landing on the exact highlight whose editor popover is open would
            // otherwise go unnoticed — the popover's `comment`/`colorHex` were captured
            // once at `showEditor` time, so hitting "Done" after this would silently
            // clobber the just-arrived remote change. Close it instead; it's already
            // `.transient` so this is consistent with how it already dismisses.
            if let openID = openEditorAnnotationID {
                // NSViewRepresentable's update path always runs on the main thread;
                // `ZoteroSyncStore` is main-actor-isolated but this method itself isn't.
                let remotelyChanged = MainActor.assumeIsolated { ZoteroSyncStore.shared.lastRemoteChangeIDs.contains(openID) }
                if remotelyChanged {
                    editorPopover?.close()
                    openEditorAnnotationID = nil
                }
            }
            PDFHighlightRendering.apply(annotations, to: doc)
            // PDFView does not reliably redraw a page on its own after
            // annotations are added/removed programmatically — without this,
            // a highlight could exist on the page model but not actually
            // appear until some unrelated interaction forced a redraw.
            view.layoutDocumentView()
        }

        /// Shows the sentence/word window currently being spoken via
        /// `highlightedSelections` — a search-result-style overlay distinct from
        /// `currentSelection`, so it never touches the real text selection or the
        /// stored-highlight creation flow. `autoScroll` mirrors the reflow view's
        /// "only jump the page when following speech is wanted" preference.
        func applyTTSHighlight(_ text: String?, autoScroll: Bool, currentPage: Int, in view: PDFView) {
            guard let doc = view.document else { return }
            let marker = String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            guard !marker.isEmpty else {
                view.highlightedSelections = nil
                return
            }
            let matches = doc.findString(marker, withOptions: [.caseInsensitive])
            guard let best = matches.first(where: { sel in
                sel.pages.first.map { doc.index(for: $0) >= currentPage } ?? false
            }) ?? matches.first else {
                view.highlightedSelections = nil
                return
            }
            view.highlightedSelections = [best]
            if autoScroll {
                keepFollowedAlong(best, in: view)
            }
        }

        /// Pins the read-aloud selection just above vertical center in the
        /// viewport, teleprompter-style, instead of `PDFView.go(to:)`'s default
        /// behavior of performing the smallest scroll that makes the selection
        /// visible at all — which could leave it sitting right at the bottom edge.
        /// Scrolls the underlying clip view directly (rather than approximating
        /// via a `PDFDestination`) so the target lands at a precise fraction of
        /// the viewport, and is gated by a small hysteresis band so word-by-word
        /// highlight updates (word-window mode) don't retrigger a scroll on every
        /// single word once the selection is already near the target line.
        private func keepFollowedAlong(_ selection: PDFSelection, in view: PDFView) {
            guard let page = selection.pages.first,
                  let clipView = view.documentView?.enclosingScrollView?.contentView
            else {
                view.go(to: selection)
                return
            }
            let viewBounds = view.convert(selection.bounds(for: page), from: page)
            let targetY = view.bounds.height * 0.42
            let delta = viewBounds.midY - targetY
            guard abs(delta) > 24 else { return }

            var origin = clipView.bounds.origin
            origin.y += delta
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(origin)
            } completionHandler: {
                view.documentView?.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }

        /// Turns the view's current text selection into a new stored highlight
        /// (via `onCreateHighlight`) rather than building the `PDFAnnotation`
        /// here directly — the new record round-trips back down through
        /// `annotations` and is placed by the same `refreshHighlights` path as
        /// every other highlight, so there is exactly one placement path.
        /// Geometry (`rects`) is captured from the live selection right now,
        /// rather than re-derived later by searching for the text — a
        /// multi-line selection does not reliably round-trip through
        /// `PDFDocument.findString`, which put the highlight (and the popover
        /// anchored to it) in the wrong place.
        func createHighlightFromSelection(in view: PDFView) {
            guard let doc = view.document,
                  let selection = view.currentSelection,
                  let page = selection.pages.first,
                  let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            let rects = PDFHighlightRendering.rects(for: selection, on: page)
            guard !rects.isEmpty else { return }
            onCreateHighlight?(doc.index(for: page), text, rects, page.label)
        }

        /// Opens the highlight editor when a click lands on an existing
        /// highlight. Deliberately does *not* clear `view.currentSelection` on
        /// a miss — this recognizer can still fire at the tail end of a short
        /// drag-select, and clearing the selection here raced with
        /// `createHighlightFromSelection` reading it right after, silently
        /// dropping the selection a highlight was about to be made from.
        /// `PDFView` already deselects natively on a plain click elsewhere.
        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? PDFView else { return }
            let point = gesture.location(in: view)
            guard let page = view.page(for: point, nearest: false) else { return }
            let pagePoint = view.convert(point, to: page)
            guard let hit = PDFHighlightRendering.managedAnnotation(at: pagePoint, on: page),
                  let id = PDFHighlightRendering.recordID(for: hit),
                  let record = lastAnnotations.first(where: { $0.id == id })
            else { return }
            showEditor(for: record, near: hit.bounds, on: page, in: view)
        }

        private func showEditor(for record: PDFHighlightAnnotation, near pageBounds: CGRect, on page: PDFPage, in view: PDFView) {
            editorPopover?.close()
            let anchorRect = view.convert(pageBounds, from: page)
            let editor = HighlightEditorView(
                annotation: record,
                onSave: { [weak self] updated in
                    self?.onEditHighlight?(updated)
                    self?.editorPopover?.close()
                    self?.openEditorAnnotationID = nil
                },
                onDelete: { [weak self] in
                    self?.onDeleteHighlight?(record.id)
                    self?.editorPopover?.close()
                    self?.openEditorAnnotationID = nil
                }
            )
            let controller = NSHostingController(rootView: editor)
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.behavior = .transient
            popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
            editorPopover = popover
            openEditorAnnotationID = record.id
        }
    }
}

/// Small editor shown in a popover when clicking an existing highlight:
/// change its color or comment, or delete it.
struct HighlightEditorView: View {
    let annotation: PDFHighlightAnnotation
    var onSave: (PDFHighlightAnnotation) -> Void
    var onDelete: () -> Void

    @State private var comment: String
    @State private var colorHex: String

    init(annotation: PDFHighlightAnnotation, onSave: @escaping (PDFHighlightAnnotation) -> Void, onDelete: @escaping () -> Void) {
        self.annotation = annotation
        self.onSave = onSave
        self.onDelete = onDelete
        _comment = State(initialValue: annotation.comment)
        _colorHex = State(initialValue: annotation.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(HighlightSwatches.all) { swatch in
                    Circle()
                        .fill(Color(hex: swatch.hex) ?? .yellow)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(
                                PaperTheme.accent,
                                lineWidth: colorHex.uppercased() == swatch.hex.uppercased() ? 2.5 : 0
                            )
                        )
                        .onTapGesture { colorHex = swatch.hex }
                }
            }
            TextEditor(text: $comment)
                .font(.system(size: 12))
                .frame(width: 220, height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PaperTheme.stroke, lineWidth: 1))
            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                Spacer()
                Button("Done") {
                    var updated = annotation
                    updated.comment = comment
                    updated.color = colorHex
                    onSave(updated)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

// MARK: - Web content (HTML / EPUB chapter / extracted PDF text)

struct WebContentView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    var preset: ReadingPreset
    var highlightSentence: String?
    var autoScroll: Bool = true
    var scrollToPage: Int? = nil
    var onVisiblePage: ((Int) -> Void)? = nil
    var selection: ReaderSelection?
    var search: SearchCommand = SearchCommand()

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let uc = config.userContentController
        uc.add(context.coordinator, name: "pageVisible")
        uc.add(context.coordinator, name: "selectionChanged")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.onVisiblePage = onVisiblePage
        context.coordinator.selection = selection
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onVisiblePage = onVisiblePage
        coordinator.selection = selection

        // The highlighted sentence is deliberately NOT part of this string. Baking it
        // in meant every spoken sentence rebuilt and reloaded the whole document,
        // which reset scroll position and made long papers crawl.
        let styled = Self.wrap(html: html, preset: preset)
        if coordinator.lastHTML != styled {
            coordinator.lastHTML = styled
            coordinator.isLoaded = false
            coordinator.pendingScrollPage = scrollToPage
            view.loadHTMLString(styled, baseURL: baseURL ?? Bundle.main.resourceURL)
        } else if let scrollToPage {
            if coordinator.lastScrolledPage != scrollToPage {
                coordinator.scroll(to: scrollToPage, in: view)
            }
        } else {
            coordinator.lastScrolledPage = nil
        }

        let sentence = highlightSentence ?? ""
        if coordinator.lastHighlight != sentence || coordinator.lastAutoScroll != autoScroll {
            coordinator.lastHighlight = sentence
            coordinator.lastAutoScroll = autoScroll
            coordinator.applyHighlight(sentence, autoScroll: autoScroll, in: view)
        }

        if coordinator.lastSearch != search {
            coordinator.lastSearch = search
            coordinator.runSearch(search, in: view)
        }

        VisualFilters.apply(preset, to: view)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        let uc = nsView.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "pageVisible")
        uc.removeScriptMessageHandler(forName: "selectionChanged")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML: String = ""
        var pendingScrollPage: Int?
        var lastScrolledPage: Int?
        var lastHighlight: String = ""
        var lastAutoScroll: Bool = true
        var lastSearch = SearchCommand()
        var isLoaded = false
        var onVisiblePage: ((Int) -> Void)?
        var selection: ReaderSelection?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "pageVisible":
                guard let page = message.body as? Int else { return }
                DispatchQueue.main.async { self.onVisiblePage?(page) }
            case "selectionChanged":
                let text = message.body as? String
                Task { @MainActor in self.selection?.update(text) }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let page = pendingScrollPage {
                scroll(to: page, in: webView)
                pendingScrollPage = nil
            }
            if !lastHighlight.isEmpty {
                applyHighlight(lastHighlight, autoScroll: lastAutoScroll, in: webView)
            }
        }

        func scroll(to page: Int, in webView: WKWebView) {
            lastScrolledPage = page
            webView.evaluateJavaScript(
                "document.getElementById('page-\(page)')?.scrollIntoView({block:'start', behavior:'smooth'});",
                completionHandler: nil
            )
        }

        func applyHighlight(_ sentence: String, autoScroll: Bool, in webView: WKWebView) {
            guard isLoaded else { return }
            webView.evaluateJavaScript(
                "window.__readerHighlight && window.__readerHighlight(\(jsLiteral(sentence)), \(autoScroll));",
                completionHandler: nil
            )
        }

        func runSearch(_ command: SearchCommand, in webView: WKWebView) {
            guard isLoaded, !command.query.isEmpty else { return }
            // window.find gives native next/previous, wrapping and scrolling.
            webView.evaluateJavaScript(
                "window.find(\(jsLiteral(command.query)), false, \(command.forward ? "false" : "true"), true);",
                completionHandler: nil
            )
        }
    }

    /// JSON-escaped string safe to paste into a JS expression.
    static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    static func wrap(html: String, preset: ReadingPreset) -> String {
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
        let zoom = max(0.1, preset.zoomPercent / 100.0)

        let script = """
        <script>
        (function () {
          function clearMarks() {
            document.querySelectorAll('mark.tts-current').forEach(function (m) {
              var p = m.parentNode;
              while (m.firstChild) p.insertBefore(m.firstChild, m);
              p.removeChild(m);
              p.normalize();
            });
          }
          // Keeps the actively-read text pinned just above vertical center, like a
          // teleprompter, rather than only correcting once it has scrolled fully
          // out of view. A single persistent rAF loop eases toward the target
          // each frame; restarting it on every highlight update (as opposed to
          // firing a fresh `scrollIntoView` animation per call) means rapid
          // word-by-word updates in word-window mode glide continuously instead
          // of fighting a stack of overlapping smooth-scroll animations.
          var FOLLOW_TARGET_FRACTION = 0.42;
          var followRAF = null;
          function followAlong(mark) {
            var scroller = document.scrollingElement || document.documentElement;
            function step() {
              var r = mark.getBoundingClientRect();
              var current = r.top + r.height / 2;
              var target = window.innerHeight * FOLLOW_TARGET_FRACTION;
              var delta = current - target;
              if (Math.abs(delta) < 1) { followRAF = null; return; }
              scroller.scrollTop += delta * 0.2;
              followRAF = requestAnimationFrame(step);
            }
            followRAF = requestAnimationFrame(step);
          }

          window.__readerHighlight = function (text, autoScroll) {
            if (followRAF) { cancelAnimationFrame(followRAF); followRAF = null; }
            clearMarks();
            if (!text) return;
            var walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            var node;
            while ((node = walk.nextNode())) {
              var i = node.nodeValue.indexOf(text);
              if (i < 0) continue;
              var range = document.createRange();
              range.setStart(node, i);
              range.setEnd(node, i + text.length);
              var mark = document.createElement('mark');
              mark.className = 'tts-current';
              try { range.surroundContents(mark); } catch (e) { return; }
              if (autoScroll) followAlong(mark);
              return;
            }
          };

          document.addEventListener('selectionchange', function () {
            var s = document.getSelection();
            var t = s ? s.toString() : '';
            if (window.webkit && window.webkit.messageHandlers.selectionChanged) {
              window.webkit.messageHandlers.selectionChanged.postMessage(t);
            }
          });

          document.addEventListener('DOMContentLoaded', function () {
            var sections = Array.prototype.slice.call(document.querySelectorAll('section.page'));
            if (!sections.length || !(window.webkit && window.webkit.messageHandlers.pageVisible)) return;
            var io = new IntersectionObserver(function (entries) {
              var best = null;
              for (var i = 0; i < entries.length; i++) {
                var e = entries[i];
                if (!e.isIntersecting) continue;
                if (!best || e.intersectionRatio > best.intersectionRatio) best = e;
              }
              if (best) {
                var idx = parseInt(best.target.getAttribute('data-page') || '0', 10);
                window.webkit.messageHandlers.pageVisible.postMessage(idx);
              }
            }, { root: null, threshold: [0.15, 0.35, 0.55] });
            sections.forEach(function (s) { io.observe(s); });
          });
        })();
        </script>
        """

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          \(face)
          html, body { background: \(bg); color: \(fg); margin: 0; }
          body {
            zoom: \(String(format: "%.3f", zoom));
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
          mark.tts-current { background: rgba(255, 220, 120, 0.7); color: inherit; }
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
        </style></head><body>\(html)\(script)</body></html>
        """
    }
}

// MARK: - Extracted / reflow text (one continuous scroll document)

struct ExtractedTextView: View {
    let pages: [ExtractedPage]
    var preset: ReadingPreset
    @Binding var currentPage: Int
    var highlightSentence: String
    var autoScroll: Bool = true
    var selection: ReaderSelection?
    var goToPage: Int? = nil
    var search: SearchCommand = SearchCommand()

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
            autoScroll: autoScroll,
            scrollToPage: goToPage,
            onVisiblePage: { page in
                if currentPage != page { currentPage = page }
            },
            selection: selection,
            search: search
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(preset.backgroundColor)
    }
}
