import SwiftUI

/// Fallback for PDFs not opened from `~/Zotero/storage/...` (the free, automatic
/// match `ZoteroStorageResolver` handles) — the user pastes Zotero's own "Copy Item
/// Link" URL for the PDF *attachment* (not the parent reference), and the trailing
/// 8-character item key is extracted from it. Deliberately simpler than a
/// filename-search-and-disambiguate UI.
struct ZoteroLinkPickerView: View {
    let documentKey: String
    var onLink: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pastedLink: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link to Zotero")
                .font(.headline)
            Text("In Zotero, right-click this PDF's **attachment** (not the parent reference) and choose “Copy Item Link,” then paste it below.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("zotero://select/library/items/XXXXXXXX", text: $pastedLink)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Link") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pastedLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func link() {
        guard let key = Self.extractItemKey(from: pastedLink) else {
            errorMessage = "Couldn't find an item key in that link."
            return
        }
        onLink(key)
        dismiss()
    }

    /// Zotero item keys are 8 uppercase alphanumeric characters. "Copy Item Link"
    /// URLs (both the `zotero://select/...` and `https://www.zotero.org/.../items/...`
    /// forms) end with one as the final path component.
    static func extractItemKey(from link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard candidate.count == 8,
              candidate.allSatisfy({ ($0.isASCII && $0.isLetter && $0.isUppercase) || $0.isNumber }) else {
            return nil
        }
        return candidate
    }
}
