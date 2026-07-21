# AccessibleReaderV2

Personal macOS academic reader (v2). Spec: [`design_document.md`](../design_document.md).

## Run

```bash
open AccessibleReader/AccessibleReader.xcodeproj
```

In Xcode, select scheme **AccessibleReaderV2**, then ⌘R.

Or open the built app:

```bash
open ~/Library/Developer/Xcode/DerivedData/AccessibleReader-*/Build/Products/Debug/AccessibleReaderV2.app
```

You should see **AccessibleReaderV2** in the menu bar and status bar (not your v1 name).

## Settings / TTS

Menu bar: **AccessibleReaderV2 → Settings…** (⌘,)

There is a **Text to Speech** section for the OpenAI API key. TTS play is also on the toolbar ▶ and ⌃Space.

## Use with Zotero

1. Build & run once (registers document types).
2. In Finder, Get Info on a PDF → Open with → Accessible Reader → Change All (repeat for EPUB/HTML as needed).
3. In Zotero, open attachments with the system default / Open With.

Each file opens in a **new window**. No tabs. Zotero stays the library.

## First run

Create your preferred preset (defaults lean toward line focus + dim surround, OpenDyslexic). Later opens use that stored preset.

## Key features

| Area | Behaviour |
|------|-----------|
| PDF | Extract/reflow first; toolbar toggle for original PDF |
| Aids | Overlay, ruler, line focus, dim surround, page focus — combinable |
| Presets | User-authored, global; `⌘1`–`⌘9` / number keys; A/B + side-by-side |
| TTS | Selection or page start; sentence highlight; paragraph chunk cache; OpenAI if key set, else macOS voices; rewind ~10s |
| Inspector | Right panel, collapsed by default (`⌘I` / toolbar) |

OpenAI key: **Settings…** or the inspector TTS section (stored in Keychain).

## Shortcuts (highlights)

- `⌘I` — inspector  
- `⌃Space` — TTS play/pause  
- `⌘⇧R` — TTS rewind ~10s  
- `⌘1`–`⌘9` — presets  
- `=` / `-` — overlay opacity (when not typing)  
- `j` / `k` — move ruler  
- Command palette via toolbar  
