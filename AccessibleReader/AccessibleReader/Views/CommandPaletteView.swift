import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var actions: [(title: String, action: () -> Void)]
    @State private var query = ""
    @FocusState private var focused: Bool

    var filtered: [(title: String, action: () -> Void)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Run a command…", text: $query)
                .textFieldStyle(.plain)
                .padding(12)
                .focused($focused)
            Divider()
            List(filtered, id: \.title) { item in
                Button(item.title) {
                    item.action()
                    isPresented = false
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .frame(maxHeight: 280)
        }
        .frame(width: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear { focused = true }
    }
}
