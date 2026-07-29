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

Copy [`.env.example`](../.env.example) to `.env.local` (or `.env`) and set `OPENAI_API_KEY`.

Key resolution order:

1. `.env.local`, then `.env` — **wins by default**
2. Keychain — used when there is no key in a file, or when you type one into **Settings…** / Reading Lab (typing a key marks it as an explicit override that survives relaunch)

The Reading Lab shows which source is live, and says so plainly if OpenAI rejects the key instead of quietly dropping to macOS voices. Both `.env` files are gitignored.

Speech uses OpenAI’s **Audio Speech API** (`tts-1-hd` by default) — Whisper is speech-to-text and is not used for reading aloud.

TTS play: bottom bar ▶ or ⌃Space. Select text first to start from the selection; play/pause resumes where it stopped.

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

## Shortcuts

| Key | Action |
|---|---|
| `⌘I` | Reading Lab (inspector) |
| `⌘K` | Command palette |
| `⌘1`–`⌘9` | Presets (bare `1`–`9` also work) |
| `⌘F` / `⌘G` / `⌘⇧G` | Find / next / previous |
| `⌘←` / `⌘→` | Previous / next page |
| `⌘⇧E` | Original ⇄ reflow PDF |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / actual size |
| `⌘⇧9` / `⌘⇧8` | Fit width / fit page |
| `⌘⌥T` / `⌘⌥P` | Contents / thumbnails |
| `⌘⇧O` | Overlay on/off |
| `⌘]` / `⌘[` | Overlay stronger / weaker |
| `⌘⇧L` / `⌘⇧J` / `⌘⇧D` / `⌘⇧U` | Ruler / line focus / dim surround / page focus |
| `⌃Space` | TTS play/pause |
| `⌘⇧R` | TTS rewind ~10s |
| `⌘.` / `⌘⇧,` | Speech faster / slower |
| `⌘⇧B` / `⌘\` | A/B compare / side-by-side |
| `=` / `-` | Overlay opacity (when not typing) |
| `j` / `k` | Move ruler |

Full screen is the standard macOS `⌃⌘F`.  
