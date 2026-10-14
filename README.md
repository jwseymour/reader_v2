# Accessible Reader

A native macOS reader for academic papers, built for readers with **dyslexia, ADHD, and pattern glare**. It opens PDFs, EPUBs, and HTML straight from Zotero and puts the reader in a pre-tuned, low-distraction reading environment.

> Built with SwiftUI, PDFKit, and AppKit · macOS 14+ · ~7,000 lines of Swift

## Why

Most PDF readers are optimised for annotation and library management, not for comfortable reading. I built this for my own needs: research papers are dense enough without fighting the page. The app stays out of the way and lets me tune the reading surface until it's quiet enough to keep going.

## Features

- **Reflowable PDFs** – a custom extractor (`PDFExtractor`) turns PDF content streams into clean, reflowable text with OpenDyslexic and adjustable typography; one key toggles back to the original PDF.
- **Combinable reading aids** – colour overlay (for pattern glare), reading ruler, line focus, soft dim-surround, and page focus.
- **Presets** – save any combination of aids and typography, switch with `⌘1`–`⌘9`, and compare with A/B or side-by-side views.
- **Text-to-speech** – OpenAI's speech API (with macOS voice fallback), sentence-level highlighting, paragraph chunk caching, and rewind.
- **Two-way Zotero sync** – highlights and notes made locally sync with your Zotero library via the Zotero Web API, with local-first writes that never block on the network. Includes a streaming client and attachment path resolution.
- **Keyboard-first** – command palette (`⌘K`), full shortcut set, minimal chrome, collapsible inspector ("Reading Lab").

## Architecture

```
AccessibleReader/AccessibleReader/
├── App/        App entry point, window/document lifecycle
├── Document/   Document model, PDF text extraction
├── Models/     Presets, highlight annotations, document kinds
├── Stores/     Observable singletons: presets, settings, annotations, Zotero sync
├── Zotero/     Web API client, streaming client, models, storage resolver
├── TTS/        Speech controller and chunking/caching
├── Theme/      Paper themes, reader fonts
└── Views/      SwiftUI views: reader window, inspector, command palette, overlays
```

Design notes: stores are the local source of truth, and Zotero sync is layered on top as fire-and-forget pushes after local mutations have been saved. The full product spec is in [`docs/design_document.md`](docs/design_document.md).

## Build & run

Requires macOS 14+ and Xcode 15+.

```bash
git clone https://github.com/jwseymour/reader_v2.git
cd reader_v2
open AccessibleReader/AccessibleReader.xcodeproj
```

Select the **AccessibleReaderV2** scheme and press ⌘R. A sample document is in [`sample/demo.html`](sample/demo.html).

### Optional configuration

Text-to-speech via OpenAI needs an API key. Copy [`.env.example`](.env.example) to `.env.local` and set `OPENAI_API_KEY` (or enter it in **Settings…**, which stores it in the Keychain). Without a key the app falls back to macOS voices. `.env*` files are gitignored.

### Using with Zotero

Set the app as the default for PDF/EPUB/HTML (Finder → Get Info → Open with → Change All). Each file opens in its own window; Zotero remains the library.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `⌘I` | Reading Lab (inspector) |
| `⌘K` | Command palette |
| `⌘1`–`⌘9` | Presets |
| `⌘F` / `⌘G` / `⌘⇧G` | Find / next / previous |
| `⌘⇧E` | Original ⇄ reflow PDF |
| `⌘⇧O` | Overlay on/off |
| `⌘⇧L` / `⌘⇧J` / `⌘⇧D` / `⌘⇧U` | Ruler / line focus / dim surround / page focus |
| `⌃Space` | TTS play/pause |
| `⌘⇧R` | TTS rewind ~10s |
| `⌘⇧B` / `⌘\` | A/B compare / side-by-side |
| `j` / `k` | Move ruler |

## License

MIT, see [LICENSE](LICENSE). Bundled OpenDyslexic font is under the SIL OFL (`Resources/Fonts/OFL.txt`).
