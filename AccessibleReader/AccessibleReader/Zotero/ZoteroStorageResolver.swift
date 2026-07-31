import Foundation

/// Matches a locally-open PDF to its Zotero attachment item key, without any network
/// call, by exploiting how Zotero lays out managed ("stored") attachments on disk:
/// `~/Zotero/storage/<8-CHAR-ITEM-KEY>/Some Filename.pdf` — the storage folder name
/// *is* the attachment's Zotero item key. Confirmed against this user's real library:
/// every sampled PDF attachment uses this layout (`linkMode` "imported file").
///
/// Files opened from anywhere else (linked, not stored, attachments) have no such
/// shortcut — `ZoteroLinkStore`'s manual-link flow covers that case.
enum ZoteroStorageResolver {
    static func attachmentKey(for fileURL: URL) -> String? {
        let storageRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Zotero/storage", isDirectory: true)
            .standardizedFileURL.path
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent().path == storageRoot else { return nil }
        let key = parent.lastPathComponent
        guard key.count == 8, key.allSatisfy({ $0.isASCII && $0.isLetter && $0.isUppercase || $0.isNumber }) else {
            return nil
        }
        return key
    }
}
