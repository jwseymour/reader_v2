import SwiftUI
import UniformTypeIdentifiers

@main
struct AccessibleReaderApp: App {
    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    init() {
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
            CommandMenu("Reading") {
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])
                Button("Toggle Overlay") {
                    PresetStore.shared.updateActive { $0.overlayEnabled.toggle() }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Play/Pause TTS") {
                    NotificationCenter.default.post(name: .toggleTTS, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [.control])
                Button("Rewind TTS 10s") {
                    NotificationCenter.default.post(name: .rewindTTS, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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
                    Text("AccessibleReaderV2")
                        .font(.title2.weight(.semibold))
                    Text("This is version 2 — not your v1 app.")
                        .foregroundStyle(.secondary)
                }
                Section("Text to Speech") {
                    SecureField("OpenAI API Key", text: $settings.openAIAPIKey)
                    Toggle("Prefer OpenAI TTS", isOn: Binding(
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
                    Text("If no key is set, macOS voices are used. Play TTS from the toolbar ▶ or ⌃Space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Presets") {
                    if let id = settings.preferredPresetID,
                       let name = presets.presets.first(where: { $0.id == id })?.name {
                        Text("Preferred default: \(name)")
                    } else {
                        Text("No preferred preset yet")
                    }
                }
            }
            .frame(width: 460, height: 360)
            .padding()
        }
    }

    private static func registerFonts() {
        if let url = Bundle.main.url(forResource: "OpenDyslexic-Regular", withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Notification.Name {
    static let toggleInspector = Notification.Name("toggleInspector")
    static let toggleTTS = Notification.Name("toggleTTS")
    static let rewindTTS = Notification.Name("rewindTTS")
}
