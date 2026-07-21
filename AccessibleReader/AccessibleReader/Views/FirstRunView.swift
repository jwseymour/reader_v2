import SwiftUI

struct FirstRunView: View {
    @ObservedObject var presets: PresetStore
    @ObservedObject var settings: SettingsStore
    @State private var name = "Daily"
    @State private var enableLineFocus = true
    @State private var enableDim = true
    @State private var enableOverlay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome")
                .font(.largeTitle.weight(.semibold))
            Text("Set up your preferred reading configuration. Papers will open with this preset from now on. You can change everything later in the inspector.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle("Line focus (ADHD)", isOn: $enableLineFocus)
            Toggle("Dim surround", isOn: $enableDim)
            Toggle("Start with a cream overlay (pattern glare)", isOn: $enableOverlay)

            Text("Default font: OpenDyslexic")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Start reading") {
                var p = ReadingPreset.starter
                p.name = name.isEmpty ? "Daily" : name
                p.shortcutSlot = 1
                p.lineFocusEnabled = enableLineFocus
                p.dimSurroundEnabled = enableDim
                p.overlayEnabled = enableOverlay
                if enableOverlay {
                    p.overlayColorHex = "#F5E6C8"
                    p.overlayOpacity = 0.35
                }
                presets.upsert(p)
                presets.activate(p.id)
                settings.preferredPresetID = p.id
                settings.hasCompletedFirstRun = true
            }
            .buttonStyle(.borderedProminent)
            .tint(PaperTheme.accent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 480, height: 420)
        .background(PaperTheme.paper)
    }
}
