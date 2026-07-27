import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var actions: [(title: String, action: () -> Void)]
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var filtered: [(title: String, action: () -> Void)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(q) }
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
                            Button {
                                item.action()
                                isPresented = false
                            } label: {
                                HStack {
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(PaperTheme.ink)
                                    Spacer()
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
                .frame(maxHeight: 280)
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
        .frame(width: 440)
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
