import SwiftUI

struct FirstRunView: View {
    @ObservedObject var presets: PresetStore
    @ObservedObject var settings: SettingsStore
    @State private var name = "Daily"
    @State private var enableLineFocus = true
    @State private var enableDim = true
    @State private var enableOverlay = false

    var body: some View {
        HStack(spacing: 0) {
            // Atmosphere panel
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.22, green: 0.38, blue: 0.35),
                        Color(red: 0.14, green: 0.22, blue: 0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessible Reader")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("A quiet place to read papers — tuned for glare, dyslexia, and focus.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
            }
            .frame(width: 200)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set your daily preset")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(PaperTheme.ink)
                    Text("Papers will open with this configuration. Everything is editable later in the Reading Lab.")
                        .font(.system(size: 12))
                        .foregroundStyle(PaperTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preset name")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PaperTheme.inkTertiary)
                    TextField("Daily", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 10) {
                    setupToggle("Line focus", subtitle: "Keep a few lines bright", isOn: $enableLineFocus)
                    setupToggle("Dim surround", subtitle: "Soft gradient fade outside focus", isOn: $enableDim)
                    setupToggle("Cream overlay", subtitle: "Start exploring pattern-glare colours", isOn: $enableOverlay)
                }

                Text("Default font: OpenDyslexic")
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.inkTertiary)

                Spacer()

                Button {
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
                } label: {
                    Text("Start reading")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(PaperTheme.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PaperTheme.elevated)
        }
        .frame(width: 560, height: 420)
        .preferredColorScheme(.light)
    }

    private func setupToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PaperTheme.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.inkTertiary)
            }
        }
        .toggleStyle(.switch)
        .tint(PaperTheme.accent)
    }
}
