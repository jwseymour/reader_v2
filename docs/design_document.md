# Accessible Academic Reader
## Product Design Document (v1)

**Status:** Design Specification  
**Target Platform:** macOS (Apple Silicon and Intel)  
**Primary User:** Jack (personal tool)  
**Designed for:** Pattern glare, dyslexia, and ADHD focus  
**Project Goal:** A distraction-free, highly accessible document reader for academic literature opened from Zotero — tuned to one person’s comfort, not a general product audience.

---

# Product Identity

This is a **personal** reading environment. It is not designed for multi-user onboarding, marketplace presets, or broad accessibility checklists.

It optimises specifically for:

1. **Pattern glare** — colour overlays and visual softening discovered through experimentation
2. **Dyslexia** — reflowable text, OpenDyslexic, spacing and typography controls when text is available
3. **ADHD focus** — line focus, dim-surround, and other combinable reading aids that reduce distraction

The first moment of delight: a paper opens already in the **stored preferred preset**, full reading surface ready, with almost no chrome in the way.

---

# Vision

Reading research papers is cognitively demanding even without accessibility needs. Existing PDF readers optimise for annotation and document management rather than comfortable, adaptable reading.

This application is **not** a reference manager, note-taking app, or annotation platform.

It should become:

> *The most comfortable possible environment for reading academic papers.*

Settings should be easy to experiment with, save as presets, and compare. The reader should stay out of the way so attention stays on the paper.

---

# Project Philosophy

## This application is NOT

- A Zotero replacement
- A literature manager
- A note taking application
- An annotation tool
- A PDF editor
- An AI assistant (beyond TTS synthesis)
- A citation manager

These may become future extensions, but **are explicitly out of scope for Version 1.**

---

## This application IS

A dedicated reading environment that provides:

- Maximum reading comfort for pattern glare, dyslexia, and ADHD focus
- Instant experimentation via presets and compare tools
- Minimal, always-visible chrome
- Fast document opening from Zotero / Finder
- Extracted/reflow text when possible, with easy fallback to the original PDF
- Soft, warm, paper-like visual language
- Excellent typography when text is available
- Support for common academic formats

---

# Primary Goals

## Goal 1 — Comfortable Reading

Every feature exists because it can improve reading comfort. Comfort takes precedence over visual polish for its own sake.

---

## Goal 2 — Accessibility as the Product

Accessibility is not an extra. Visual and typographic aspects of reading should be configurable. The app helps **discover** what works (especially pattern-glare overlays) rather than shipping a fixed “best” mode.

---

## Goal 3 — Zero Friction from Zotero

Ideal workflow:

```
Find paper in Zotero
↓
Open attachment (PDF / EPUB / HTML snapshot)
↓
Accessible Reader opens in a new window
↓
Stored preferred preset is already applied
↓
Begin reading
```

No importing. No copying. No manual conversion.

---

## Goal 4 — Experimentation

Presets are the defining feature. Changing settings should feel immediate. Compare tools (A/B toggle and side-by-side) make it practical to settle on a daily configuration — including overlay colours that are not known in advance and will be found through use.

---

# Target File Types

Version 1 supports:

- PDF
- EPUB
- Zotero Web Snapshots (HTML snapshots)

These cover the vast majority of academic reading.

---

# Zotero Integration (Highest Priority)

Zotero remains the library and source of truth. This app is only the viewer.

## Desired experience

Browse in Zotero. Open an attachment (PDF, EPUB, or HTML snapshot). It opens in Accessible Reader instead of another app.

## How integration works

Zotero stores attachments as normal files on disk (stored or linked). PDFs, EPUBs, and webpage snapshots can be opened externally by the OS. Webpage snapshots may include multiple HTML assets, so snapshot support must preserve relative resources rather than assuming a single standalone HTML file.

The app should behave as a normal macOS document-based application:

- Register as a handler for PDF
- Register as a handler for EPUB
- Register as a handler for HTML snapshot entry files
- Support Finder, drag-and-drop, “Open With”, and recent documents

No Zotero plugin is required for Version 1. A future plugin may deepen integration but is deferred.

Do **not** read or write the Zotero database. Treat attachments as read-only file paths.

---

# Window and Document Model

- **No tabs.**
- **One document per window.**
- **Multiple windows allowed** (e.g. several papers open from Zotero).
- Opening a file from Zotero or Finder opens a **new window**.
- **Reading position is not remembered** across sessions in v1 (always start at the beginning / default view).

---

# Reading Surface and Chrome

## Chrome rules

- Chrome is **always visible but minimal** — not auto-hidden, not fullscreen-only.
- The document occupies almost the entire window.
- Prefer keyboard shortcuts and a command palette over deep menus.
- Soft, warm, **paper-like** shell (LiquidText-adjacent), not clinical system grey.

## Right inspector

- Accessibility and reading controls live primarily in a **right inspector panel**.
- Inspector is **collapsed by default**.
- Toggle open/closed with a keyboard shortcut.
- When open, it should feel part of the paper-like shell, not a heavy preferences window.

## Toggleable navigation

Independently toggleable (not permanently consuming layout):

- Table of contents
- Page thumbnails (PDF)
- Search

Page number and a light progress indicator may remain in the minimal chrome.

## First run

On first run, show a **preset / setup picker** so a preferred configuration can be created and stored.

After that, documents open silently into the **stored preferred preset**. No ongoing tour or tip chrome.

## Chrome and appearance

**App chrome follows the active reading preset** (backgrounds, warmth, contrast), not a separate macOS light/dark appearance setting.

---

# PDF: Extracted Text vs Original

Academic PDFs are often two-column and inflexible. Version 1 supports both approaches.

## Default: extract / reflow first

When a PDF opens, **attempt text extraction and reflow** first. This unlocks:

- OpenDyslexic and other fonts
- Line / paragraph / character / word spacing
- Reading width and margins
- Reliable text selection for TTS

## Fallback: original visual PDF

Extraction will not always work well. There must be an **easy, obvious control** to switch to **Show original PDF** (visual-layer rendering only) when extraction fails or looks wrong.

On the original PDF, visual-layer accessibility still applies: colour overlay, brightness/contrast/saturation/gamma, invert, zoom, ruler, line focus, page focus, dim-surround.

## EPUB and HTML

EPUB and HTML snapshots are already text-native. They use the typography and reading-aid stack directly; the extract-vs-original fork is primarily a PDF concern.

---

# Reading Aids (Combinable)

All of the following are **independent** and may be on in **any combination**. None are mutually exclusive modes.

## Colour overlay

Configurable colour and opacity. Custom colour picker. Useful starter swatches may exist as quick picks (cream, light yellow, light blue, mint, pink, grey), but **pattern-glare colours that work for Jack are unknown in advance** and will be discovered through presets — not shipped as a fixed “correct” set.

## Dim surround / focus reading

Dim the area outside the active reading region; emphasise the active area.

## Reading ruler

Movable horizontal ruler.

Configurable: height, opacity, colour, edge softness.  
Controllable by mouse and keyboard.

## Line focus

Dim everything except a few lines.

Configurable: number of visible lines, fade amount, transition.

## Page focus

Emphasise one page at a time (especially useful for long PDFs in continuous scroll).

## Suggested personal lean (not a locked built-in)

A sensible starting combination for ADHD focus: **line focus + dim-surround**, with overlay and ruler available for experimentation. This is guidance for defaults during first-run setup, not a shipped named preset pack.

---

# Typography and Visual Adjustments

## When text is available (extracted PDF, EPUB, HTML)

- **Default font:** OpenDyslexic
- Font selection (additional fonts allowed)
- Font size
- Line spacing
- Paragraph spacing
- Character spacing
- Word spacing
- Reading width / column width
- Margins
- Text colour
- Background colour (independent from overlay)

Exact size and spacing values are left configurable and will be settled through use; they are intentionally not prescribed in this document.

## When on original PDF (visual layer)

Apply what the renderer allows: overlay, background treatment where feasible, brightness, contrast, saturation, gamma, invert, zoom. Text recolour and typography may be limited and should degrade gracefully.

## Zoom and layout

- Pinch, keyboard shortcuts, percentage entry
- Fit width, fit page
- Continuous scroll and page-by-page

## Optional / lower priority for v1

- Smart dark mode (preserve figures while improving text) — desirable, not required

---

# Presets (Major Feature)

Presets are global and apply to every document.

## Scope

- **Global**, not per-document
- **No shipped named preset library** — presets are user-created
- First run helps create/select a default; that choice is stored as the preferred preset
- Every configurable option belongs in a preset: overlay, colours, zoom, ruler, focus aids, typography, spacing, TTS-related preferences, and remaining accessibility options
- Switching presets is instant

## Management

- Create, rename, duplicate, delete
- Export, import
- Reset

## Switching during reading

Few presets are expected. Primary switch path: **number keys** bound to presets.

## Compare (both in v1)

1. **A/B toggle** — same document, flip between two presets with a shortcut  
2. **Side-by-side** — split view, same page, two presets visible at once  

Compare exists so pattern-glare overlays and focus combinations can be evaluated quickly without relying on memory.

---

# Text to Speech

TTS is a first-class feature.

## Providers

- **Primary:** OpenAI TTS when an API key is configured (local settings, personal use)
- **Fallback / offline:** native macOS voices

## Playback model

- Select text → Play starts from the selection
- If nothing is selected → start from the **beginning of the current page**
- **Highlight the current sentence** being spoken
- Auto-scroll to keep the spoken sentence in view; manual scrolling remains allowed while TTS is active

## Generation and cache

- Synthesize in **paragraph-sized chunks**, not the entire document up front
- Cache audio **locally** so rewind, pause, and replay feel instant
- Prefetch the next chunk ahead of need; never block reading on full-document synthesis

## Controls (keyboard-first)

- Play / pause
- Rewind approximately **10 seconds of playback** (duration adjusted for current speed)
- Speed up / slow down
- Voice / provider selection as needed

---

# Navigation

Must support:

- Table of contents (toggleable)
- Page thumbnails for PDF (toggleable)
- Page number
- Progress indicator
- Search with next / previous result (toggleable find UI)

---

# Visual Design Language

When chrome is visible, the app should feel **soft, warm, and paper-like** — closer to LiquidText than to Preview or a clinical accessibility utility.

- Paper-like surfaces and warmth over flat system grey or pure stark white chrome
- Reading area remains the hero; inspector and nav panels should match the same material language
- Active reading preset drives chrome colouring as well as document appearance

---

# Keyboard Model

Everything important should have shortcuts. At minimum:

- Toggle inspector
- Toggle ruler, overlay, line focus, dim-surround, page focus
- Overlay opacity up / down
- Zoom
- Preset number keys
- A/B preset compare toggle; enter/exit side-by-side compare
- TTS play/pause, rewind ~10s, speed up/down
- Search
- Next / previous page
- Toggle TOC / thumbnails
- Toggle extracted vs original PDF
- Toggle fullscreen
- Command palette for less frequent actions

---

# Performance

The application should feel lightweight.

- Opening papers should be fast
- Scrolling should stay smooth on long PDFs (e.g. 500 pages), image-heavy conference papers, and textbooks
- Accessibility effects must not noticeably reduce frame rate
- TTS chunking/caching must not freeze the UI

---

# Technology Considerations (Implementation Guidance)

Implementation details stay flexible, but these constraints matter.

## Native macOS document application

Behave like a standard macOS document reader: double-click, Finder, drag-and-drop, Open With, recent documents, multiple windows.

## Rendering

Support PDF, EPUB, and HTML via mature libraries. Prefer reliability over custom parsers.

PDF extraction/reflow should use a robust extraction path with a clear fallback to visual rendering.

## Zotero compatibility

Read-only file paths only. No Zotero database access. No required plugin in v1.

## TTS

OpenAI TTS for quality when online and configured; macOS voices when offline or unconfigured. Local audio cache keyed by content chunk. Paragraph-chunk synthesis with lookahead.

---

# Out of Scope (Version 1)

Deliberately not implemented:

- Notes
- Highlights / annotation
- PDF editing
- OCR (scanned PDFs without a text layer stay visual-only)
- AI summaries or chat
- Citation generation
- Zotero database editing
- Cloud sync / multi-device sync
- Collaboration
- Research knowledge graphs
- Annotation export
- Reference management
- Web browser
- Plugin system
- Built-in named preset packs
- Tabs
- Reading-position memory across sessions
- Zotero plugin (deeper integration)

Keeping scope narrow is required to deliver an excellent personal reading experience.

---

# Deferred (Possible Later)

- Remember scroll/page position per file
- Tabs (if multi-window becomes insufficient)
- Shipped starter preset packs (only if still useful after personal presets exist)
- Zotero plugin for tighter open/routing behaviour
- Smart dark mode that preserves figures
- Broader font discovery beyond OpenDyslexic + system fonts

---

# Success Criteria

Version 1 is successful if:

- Jack can set this app as the default reader for Zotero attachments
- PDFs, EPUBs, and Zotero webpage snapshots open reliably in a new window with the stored preferred preset applied
- PDFs attempt extraction/reflow by default, with a one-step return to the original visual PDF when needed
- Reading aids combine freely; line focus + dim-surround (and overlays) make focus and pattern-glare experimentation practical
- User-authored global presets switch instantly via number keys; A/B and side-by-side compare help settle a daily setup
- TTS plays from selection or page start, highlights the spoken sentence, caches paragraph chunks locally, supports ~10s rewind and speed control, and uses OpenAI when configured (macOS voices otherwise)
- The UI stays minimal, paper-like, and focused entirely on reading — chrome follows the active preset

The application should feel like a high-quality personal accessibility reading tool, not a general-purpose document manager.
