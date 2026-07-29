import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Every menu/keyboard action a reader window can perform. Sent as a single
/// notification; each window ignores it unless it is the key window.
enum ReaderCommand: String {
    case toggleInspector
    case toggleTTS
    case rewindTTS
    case speedUp
    case speedDown
    case toggleOverlay
    case toggleRuler
    case toggleLineFocus
    case toggleDimSurround
    case togglePageFocus
    case overlayOpacityUp
    case overlayOpacityDown
    case rulerNudgeUp
    case rulerNudgeDown
    case zoomIn
    case zoomOut
    case zoomReset
    case fitWidth
    case fitPage
    case toggleTOC
    case toggleThumbnails
    case toggleOriginalPDF
    case find
    case findNext
    case findPrevious
    case nextPage
    case previousPage
    case toggleAB
    case toggleSideBySide
    case commandPalette
    case toggleShortcutsGuide
}

extension Notification.Name {
    static let readerCommand = Notification.Name("readerCommand")
}

func postReaderCommand(_ command: ReaderCommand) {
    NotificationCenter.default.post(name: .readerCommand, object: command)
}

/// One physical key combination bound to a command.
///
/// This is the single source of truth for shortcuts: `KeyCaptureView`'s event
/// monitor matches against it (the reliable path, since it intercepts before
/// AppKit dispatch — SwiftUI's `.commands` menu shortcuts lose the race to
/// whichever view, usually `WKWebView` or `PDFView`, currently has focus), and
/// the in-app shortcuts guide renders from the same list, so the two can never
/// drift apart.
struct KeyBinding: Identifiable {
    let id = UUID()
    let command: ReaderCommand
    let label: String
    let group: String
    let symbol: String
    /// The literal character AppKit reports via `charactersIgnoringModifiers`
    /// for this combo — already shift-resolved (e.g. Shift+9 reports "(", not "9").
    let character: String
    let cmd: Bool
    let ctrl: Bool
    let opt: Bool
    let shift: Bool

    init(_ command: ReaderCommand, _ label: String, group: String, symbol: String, character: String,
         cmd: Bool = false, ctrl: Bool = false, opt: Bool = false, shift: Bool = false) {
        self.command = command
        self.label = label
        self.group = group
        self.symbol = symbol
        self.character = character
        self.cmd = cmd
        self.ctrl = ctrl
        self.opt = opt
        self.shift = shift
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == character else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var required: NSEvent.ModifierFlags = []
        if cmd { required.insert(.command) }
        if ctrl { required.insert(.control) }
        if opt { required.insert(.option) }
        if shift { required.insert(.shift) }
        return flags == required
    }
}

enum ReaderShortcuts {
    static let leftArrow = "\u{F702}"
    static let rightArrow = "\u{F703}"
    static let space = " "

    /// Order here is also the section order in the guide.
    static let bindings: [KeyBinding] = [
        // General
        KeyBinding(.toggleInspector, "Toggle Reading Lab", group: "General", symbol: "⌘I", character: "i", cmd: true),
        KeyBinding(.commandPalette, "Command Palette", group: "General", symbol: "⌘K", character: "k", cmd: true),
        KeyBinding(.toggleShortcutsGuide, "Keyboard Shortcuts", group: "General", symbol: "⌘/", character: "/", cmd: true),

        // Navigation
        KeyBinding(.toggleOriginalPDF, "Original ⇄ Reflow PDF", group: "Navigation", symbol: "⌘⇧E", character: "E", cmd: true, shift: true),
        KeyBinding(.previousPage, "Previous Page", group: "Navigation", symbol: "⌘←", character: leftArrow, cmd: true),
        KeyBinding(.nextPage, "Next Page", group: "Navigation", symbol: "⌘→", character: rightArrow, cmd: true),
        KeyBinding(.toggleTOC, "Table of Contents", group: "Navigation", symbol: "⌘⌥T", character: "t", cmd: true, opt: true),
        KeyBinding(.toggleThumbnails, "Page Thumbnails", group: "Navigation", symbol: "⌘⌥P", character: "p", cmd: true, opt: true),
        KeyBinding(.find, "Find", group: "Navigation", symbol: "⌘F", character: "f", cmd: true),
        KeyBinding(.findNext, "Find Next", group: "Navigation", symbol: "⌘G", character: "g", cmd: true),
        KeyBinding(.findPrevious, "Find Previous", group: "Navigation", symbol: "⌘⇧G", character: "G", cmd: true, shift: true),

        // Zoom & View
        KeyBinding(.zoomIn, "Zoom In", group: "Zoom & View", symbol: "⌘=", character: "=", cmd: true),
        KeyBinding(.zoomIn, "Zoom In", group: "Zoom & View", symbol: "⌘=", character: "+", cmd: true, shift: true),
        KeyBinding(.zoomOut, "Zoom Out", group: "Zoom & View", symbol: "⌘-", character: "-", cmd: true),
        KeyBinding(.zoomReset, "Actual Size", group: "Zoom & View", symbol: "⌘0", character: "0", cmd: true),
        KeyBinding(.fitWidth, "Fit Width", group: "Zoom & View", symbol: "⌘⇧9", character: "(", cmd: true, shift: true),
        KeyBinding(.fitPage, "Fit Page", group: "Zoom & View", symbol: "⌘⇧8", character: "*", cmd: true, shift: true),

        // Reading Aids
        KeyBinding(.toggleOverlay, "Toggle Overlay", group: "Reading Aids", symbol: "⌘⇧O", character: "O", cmd: true, shift: true),
        KeyBinding(.overlayOpacityUp, "Overlay Stronger", group: "Reading Aids", symbol: "⌘] / =", character: "]", cmd: true),
        KeyBinding(.overlayOpacityUp, "Overlay Stronger", group: "Reading Aids", symbol: "⌘] / =", character: "="),
        KeyBinding(.overlayOpacityDown, "Overlay Weaker", group: "Reading Aids", symbol: "⌘[ / -", character: "[", cmd: true),
        KeyBinding(.overlayOpacityDown, "Overlay Weaker", group: "Reading Aids", symbol: "⌘[ / -", character: "-"),
        KeyBinding(.toggleRuler, "Toggle Ruler", group: "Reading Aids", symbol: "⌘⇧L", character: "L", cmd: true, shift: true),
        KeyBinding(.rulerNudgeUp, "Move Ruler Up", group: "Reading Aids", symbol: "K", character: "k"),
        KeyBinding(.rulerNudgeDown, "Move Ruler Down", group: "Reading Aids", symbol: "J", character: "j"),
        KeyBinding(.toggleLineFocus, "Toggle Line Focus", group: "Reading Aids", symbol: "⌘⇧J", character: "J", cmd: true, shift: true),
        KeyBinding(.toggleDimSurround, "Toggle Dim Surround", group: "Reading Aids", symbol: "⌘⇧D", character: "D", cmd: true, shift: true),
        KeyBinding(.togglePageFocus, "Toggle Page Focus", group: "Reading Aids", symbol: "⌘⇧U", character: "U", cmd: true, shift: true),

        // Speech
        KeyBinding(.toggleTTS, "Play / Pause Speech", group: "Speech", symbol: "⌃Space", character: space, ctrl: true),
        KeyBinding(.rewindTTS, "Rewind ~10s", group: "Speech", symbol: "⌘⇧R", character: "R", cmd: true, shift: true),
        KeyBinding(.speedUp, "Speech Faster", group: "Speech", symbol: "⌘.", character: ".", cmd: true),
        KeyBinding(.speedDown, "Speech Slower", group: "Speech", symbol: "⌘⇧,", character: "<", cmd: true, shift: true),

        // Presets & Compare — digit presets are handled separately (any of 1–9)
        KeyBinding(.toggleAB, "A/B Compare", group: "Presets & Compare", symbol: "⌘⇧B", character: "B", cmd: true, shift: true),
        KeyBinding(.toggleSideBySide, "Side-by-Side Compare", group: "Presets & Compare", symbol: "⌘\\", character: "\\", cmd: true)
    ]

    /// First binding matching this event, if any.
    static func match(_ event: NSEvent) -> KeyBinding? {
        bindings.first { $0.matches(event) }
    }
}

@main
struct AccessibleReaderApp: App {
    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    init() {
        DotEnv.load()
        Self.registerFonts()
    }

    var body: some Scene {
        DocumentGroup(viewing: ReaderDocument.self) { file in
            ReaderWindowView(document: file.$document, fileURL: file.fileURL)
                .environmentObject(presets)
                .environmentObject(settings)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .toolbar) {
                Button("Zoom In") { postReaderCommand(.zoomIn) }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("Zoom Out") { postReaderCommand(.zoomOut) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Actual Size") { postReaderCommand(.zoomReset) }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("Fit Width") { postReaderCommand(.fitWidth) }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                Button("Fit Page") { postReaderCommand(.fitPage) }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                Divider()
                Button("Table of Contents") { postReaderCommand(.toggleTOC) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Page Thumbnails") { postReaderCommand(.toggleThumbnails) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }

            CommandGroup(after: .textEditing) {
                Button("Find…") { postReaderCommand(.find) }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("Find Next") { postReaderCommand(.findNext) }
                    .keyboardShortcut("g", modifiers: [.command])
                Button("Find Previous") { postReaderCommand(.findPrevious) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            CommandMenu("Reading") {
                Button("Toggle Inspector") { postReaderCommand(.toggleInspector) }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Command Palette") { postReaderCommand(.commandPalette) }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Keyboard Shortcuts…") { postReaderCommand(.toggleShortcutsGuide) }
                    .keyboardShortcut("/", modifiers: [.command])
                Divider()

                Button("Original / Reflow PDF") { postReaderCommand(.toggleOriginalPDF) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Previous Page") { postReaderCommand(.previousPage) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next Page") { postReaderCommand(.nextPage) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()

                Button("Toggle Overlay") { postReaderCommand(.toggleOverlay) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Overlay Stronger") { postReaderCommand(.overlayOpacityUp) }
                    .keyboardShortcut("]", modifiers: [.command])
                Button("Overlay Weaker") { postReaderCommand(.overlayOpacityDown) }
                    .keyboardShortcut("[", modifiers: [.command])
                Button("Toggle Ruler") { postReaderCommand(.toggleRuler) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Toggle Line Focus") { postReaderCommand(.toggleLineFocus) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Toggle Dim Surround") { postReaderCommand(.toggleDimSurround) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Toggle Page Focus") { postReaderCommand(.togglePageFocus) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()

                Button("Play/Pause TTS") { postReaderCommand(.toggleTTS) }
                    .keyboardShortcut(.space, modifiers: [.control])
                Button("Rewind TTS 10s") { postReaderCommand(.rewindTTS) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Speech Faster") { postReaderCommand(.speedUp) }
                    .keyboardShortcut(".", modifiers: [.command])
                Button("Speech Slower") { postReaderCommand(.speedDown) }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                Divider()

                Button("A/B Compare") { postReaderCommand(.toggleAB) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Side-by-Side Compare") { postReaderCommand(.toggleSideBySide) }
                    .keyboardShortcut("\\", modifiers: [.command])
                Divider()

                ForEach(1...9, id: \.self) { n in
                    Button("Preset \(n)") {
                        PresetStore.shared.activateSlot(n)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
                }
            }
        }

        Settings {
            Form {
                Section {
                    Text("Accessible Reader")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("Personal academic reading environment — v2.")
                        .foregroundStyle(.secondary)
                }
                Section("Speech") {
                    SecureField("OpenAI API Key", text: $settings.openAIAPIKey)
                    Text(settings.apiKeySource.label)
                        .font(.caption)
                        .foregroundStyle(settings.apiKeyRejected ? Color.red : .secondary)
                    Toggle("Prefer OpenAI voice", isOn: Binding(
                        get: { presets.activePreset.ttsPreferOpenAI },
                        set: { v in presets.updateActive { $0.ttsPreferOpenAI = v } }
                    ))
                    Picker("OpenAI Voice", selection: Binding(
                        get: { presets.activePreset.openAIVoice },
                        set: { v in presets.updateActive { $0.openAIVoice = v } }
                    )) {
                        Text("nova").tag("nova")
                        Text("alloy").tag("alloy")
                        Text("echo").tag("echo")
                        Text("fable").tag("fable")
                        Text("onyx").tag("onyx")
                        Text("shimmer").tag("shimmer")
                    }
                    Text("Without a key, macOS voices are used. Play from the bottom bar or ⌃Space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Presets") {
                    if let id = settings.preferredPresetID,
                       let name = presets.presets.first(where: { $0.id == id })?.name {
                        Text("Default for new papers: \(name)")
                    } else {
                        Text("No preferred preset yet — set one in the Reading Lab.")
                    }
                }
            }
            .frame(width: 460, height: 400)
            .padding()
        }
    }

    private static func registerFonts() {
        if let url = Bundle.main.url(forResource: "OpenDyslexic-Regular", withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
