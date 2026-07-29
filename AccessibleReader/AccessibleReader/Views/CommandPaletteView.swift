import SwiftUI

/// One entry in the command palette. `group` clusters it under a section header
/// and `shortcut` — when present — shows the physical key combo that does the
/// same thing, so the palette never claims a shortcut exists that doesn't.
struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let group: String
    let shortcut: String?
    let action: () -> Void
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var items: [CommandPaletteItem]
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var filtered: [CommandPaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PaperTheme.accent)
                TextField("Run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .focused($focused)
                    .onChange(of: query) { _, _ in selected = 0 }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Rectangle().fill(PaperTheme.stroke).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { index, item in
                            // Items arrive pre-sorted by group, so a group boundary is
                            // just wherever the previous item's group differs.
                            if index == 0 || filtered[index - 1].group != item.group {
                                Text(item.group.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(PaperTheme.inkTertiary)
                                    .tracking(0.5)
                                    .padding(.horizontal, 14)
                                    .padding(.top, index == 0 ? 6 : 14)
                                    .padding(.bottom, 2)
                            }
                            Button {
                                item.action()
                                isPresented = false
                            } label: {
                                HStack {
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(PaperTheme.ink)
                                    Spacer()
                                    if let shortcut = item.shortcut {
                                        KeycapView(symbol: shortcut)
                                    }
                                    if index == selected {
                                        Image(systemName: "return")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(PaperTheme.inkTertiary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(index == selected ? PaperTheme.accentSoft : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
                .onChange(of: selected) { _, new in
                    withAnimation { proxy.scrollTo(new, anchor: .center) }
                }
            }

            if filtered.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 12))
                    .foregroundStyle(PaperTheme.inkTertiary)
                    .padding(.bottom, 14)
            }
        }
        .frame(width: 460)
        .background(PaperTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PaperTheme.strokeStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
        .onAppear { focused = true }
        .onKeyPress(.return) {
            guard filtered.indices.contains(selected) else { return .ignored }
            filtered[selected].action()
            isPresented = false
            return .handled
        }
        .onKeyPress(.upArrow) {
            selected = max(0, selected - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selected = min(max(0, filtered.count - 1), selected + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }
}

/// Categorized keyboard shortcut reference, built from `ReaderShortcuts.bindings`
/// — the same table that actually drives key handling — so this can never drift
/// out of sync with what the keys really do.
struct ShortcutsGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private static let groupOrder = ["General", "Navigation", "Zoom & View", "Reading Aids", "Speech", "Presets & Compare"]

    private var sections: [(group: String, bindings: [KeyBinding])] {
        var byGroup: [String: [KeyBinding]] = [:]
        for binding in ReaderShortcuts.bindings {
            byGroup[binding.group, default: []].append(binding)
        }
        return Self.groupOrder.compactMap { name in
            byGroup[name].map { (name, dedupedByCommand($0)) }
        }
    }

    /// Some commands have two physical combos (e.g. Zoom In via ⌘= or ⌘+); show one row.
    private func dedupedByCommand(_ bindings: [KeyBinding]) -> [KeyBinding] {
        var seen = Set<String>()
        var result: [KeyBinding] = []
        for binding in bindings where !seen.contains(binding.label) {
            seen.insert(binding.label)
            result.append(binding)
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(PaperTheme.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(PaperTheme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(PaperTheme.elevated)
            .overlay(alignment: .bottom) {
                Rectangle().fill(PaperTheme.stroke).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            PaperTheme.sectionLabel(section.group)
                            VStack(spacing: 0) {
                                ForEach(Array(section.bindings.enumerated()), id: \.offset) { index, binding in
                                    if index > 0 {
                                        Rectangle().fill(PaperTheme.stroke).frame(height: 1)
                                    }
                                    HStack {
                                        Text(binding.label)
                                            .font(.system(size: 13))
                                            .foregroundStyle(PaperTheme.ink)
                                        Spacer()
                                        KeycapView(symbol: binding.symbol)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }
                            }
                            .background(PaperTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(PaperTheme.stroke, lineWidth: 1)
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        PaperTheme.sectionLabel("Notes")
                        Text("Presets also switch with plain 1–9 while the reading surface has focus. Drag the ruler with the mouse, or nudge it with plain J / K.")
                            .font(.system(size: 12))
                            .foregroundStyle(PaperTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 580)
        .background(PaperTheme.panel)
    }
}

private struct KeycapView: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospaced())
            .foregroundStyle(PaperTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PaperTheme.mist)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(PaperTheme.stroke, lineWidth: 1)
            )
    }
}
