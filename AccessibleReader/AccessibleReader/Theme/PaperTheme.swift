import SwiftUI

/// Quiet library chrome: cool stone surfaces, charcoal ink, sea-glass accent.
/// Reading-surface colours still come from the active preset.
enum PaperTheme {
    // Surfaces
    static let mist = Color(red: 0.91, green: 0.925, blue: 0.91)       // #E8ECE8
    static let mistDeep = Color(red: 0.86, green: 0.88, blue: 0.86)     // #DBE0DB
    static let panel = Color(red: 0.94, green: 0.95, blue: 0.94)        // #F0F2F0
    static let elevated = Color(red: 0.97, green: 0.975, blue: 0.97)    // #F7F8F7

    // Type
    static let ink = Color(red: 0.11, green: 0.14, blue: 0.125)         // #1C241F
    static let inkSecondary = Color(red: 0.35, green: 0.40, blue: 0.37) // #59665E
    static let inkTertiary = Color(red: 0.52, green: 0.56, blue: 0.53)  // #858F87

    // Accent — sea glass
    static let accent = Color(red: 0.18, green: 0.42, blue: 0.38)       // #2E6B61
    static let accentSoft = Color(red: 0.18, green: 0.42, blue: 0.38).opacity(0.12)
    static let accentMuted = Color(red: 0.35, green: 0.55, blue: 0.50)

    // Borders / hairlines
    static let stroke = Color.black.opacity(0.07)
    static let strokeStrong = Color.black.opacity(0.12)

    // Semantic
    static let success = Color(red: 0.22, green: 0.48, blue: 0.38)
    static let warning = Color(red: 0.62, green: 0.42, blue: 0.18)

    static func chrome(for preset: ReadingPreset) -> Color {
        // Blend preset background toward mist so chrome stays calm and distinct from the page
        preset.backgroundColor
    }

    static func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(inkTertiary)
    }
}

struct OverlaySwatch: Identifiable {
    let id = UUID()
    let name: String
    let hex: String
}

enum OverlaySwatches {
    static let all: [OverlaySwatch] = [
        .init(name: "Cream", hex: "#F5E6C8"),
        .init(name: "Light Yellow", hex: "#FFF3B0"),
        .init(name: "Light Blue", hex: "#D6EAF8"),
        .init(name: "Mint", hex: "#D5F5E3"),
        .init(name: "Pink", hex: "#F5D0E6"),
        .init(name: "Grey", hex: "#D5D8DC"),
        .init(name: "Sage", hex: "#D8E4D8"),
        .init(name: "Lavender", hex: "#E4DFF0")
    ]
}

// MARK: - Shared chrome controls

struct ChromePill: View {
    let title: String
    var systemImage: String? = nil
    var active: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Color.white : PaperTheme.ink)
            .background(
                Capsule(style: .continuous)
                    .fill(active ? PaperTheme.accent : PaperTheme.elevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : PaperTheme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    var initiallyExpanded: Bool = true
    @ViewBuilder var content: () -> Content
    @State private var expanded: Bool

    init(title: String, icon: String, initiallyExpanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.initiallyExpanded = initiallyExpanded
        self.content = content
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PaperTheme.accent)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(PaperTheme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PaperTheme.inkTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PaperTheme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PaperTheme.stroke, lineWidth: 1)
        )
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PaperTheme.inkSecondary)
                Spacer()
                Text(display)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(PaperTheme.inkTertiary)
            }
            Slider(value: $value, in: range)
                .tint(PaperTheme.accent)
        }
    }
}
