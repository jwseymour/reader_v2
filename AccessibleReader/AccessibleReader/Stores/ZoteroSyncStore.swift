import Foundation

/// Orchestrates live, two-way sync between `AnnotationStore` (local source of truth)
/// and a user's Zotero library via `ZoteroClient`. Same singleton convention as
/// `AnnotationStore`/`PresetStore`/`SettingsStore`.
///
/// Local edits never block on the network — every push method is fire-and-forget,
/// called after the local mutation has already happened and saved.
@MainActor
final class ZoteroSyncStore: ObservableObject {
    static let shared = ZoteroSyncStore()

    enum Status: Equatable {
        case notConfigured
        case idle
        case syncing
        case offline
        case error(String)
    }

    @Published private(set) var status: Status = .notConfigured
    @Published private(set) var userID: Int?

    private var client: ZoteroClient?
    private var isReconciling = false
    private let lastVersionKey = "zoteroLastLibraryVersion"
    private var lastLibraryVersion: Int {
        get { UserDefaults.standard.integer(forKey: lastVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastVersionKey) }
    }
    private let streaming = ZoteroStreamingClient()

    private init() {
        streaming.onTopicUpdated = { [weak self] in
            Task { await self?.reconcileLibrary() }
        }
    }

    /// Called by `SettingsStore` whenever `zoteroAPIKey` changes, and once at launch.
    func configure(apiKey: String) {
        guard !apiKey.isEmpty else {
            client = nil
            userID = nil
            status = .notConfigured
            streaming.disconnect()
            return
        }
        client = ZoteroClient(apiKey: apiKey)
        status = .idle
        streaming.connect(apiKey: apiKey)
        Task { await resolveUserIDIfNeeded() }
    }

    private func resolveUserIDIfNeeded() async {
        guard let client, userID == nil else { return }
        do {
            userID = try await client.resolveUserID()
        } catch {
            handle(error)
        }
    }

    // MARK: - Document linking

    /// Runs once per document, from `ReaderWindowView.bootstrap()`. Tries the free
    /// storage-path match first; leaves the document unlinked (outbound push simply
    /// no-ops) if that fails — the user can link manually via `ZoteroLinkPickerView`.
    func resolveLink(documentKey: String, fileURL: URL) async {
        guard ZoteroLinkStore.shared.link(for: documentKey) == nil else {
            await reconcileLibrary()
            return
        }
        guard let attachmentKey = ZoteroStorageResolver.attachmentKey(for: fileURL) else { return }
        if userID == nil { await resolveUserIDIfNeeded() }
        guard let userID else { return }
        ZoteroLinkStore.shared.setLink(ZoteroDocumentLink(
            documentKey: documentKey, libraryID: userID,
            attachmentItemKey: attachmentKey, resolvedVia: "storagePath"
        ))
        await reconcileLibrary()
    }

    // MARK: - Outbound push (fire-and-forget from the 4 existing mutation hook points)

    func pushCreate(_ record: PDFHighlightAnnotation) async {
        guard let client, let userID else { return }
        guard let link = ZoteroLinkStore.shared.link(for: record.documentKey) else { return }
        status = .syncing
        do {
            let payload = record.zoteroCreatePayload(parentItem: link.attachmentItemKey)
            let result = try await client.createAnnotations(userID: userID, payloads: [payload])
            if let created = result.successful["0"] {
                var updated = record
                updated.zoteroItemKey = created.key
                updated.zoteroVersion = created.version
                AnnotationStore.shared.update(updated)
                status = .idle
            } else if let failure = result.failed["0"] {
                status = .error(failure.message)
            }
        } catch {
            handle(error)
        }
    }

    func pushUpdate(_ record: PDFHighlightAnnotation) async {
        guard let client, let userID else { return }
        guard let key = record.zoteroItemKey, let version = record.zoteroVersion else {
            return // never synced yet; the next reconcile's backfill pass creates it
        }
        status = .syncing
        do {
            let newVersion = try await client.updateAnnotation(
                userID: userID, key: key, version: version, comment: record.comment, color: record.color,
                type: record.kind.rawValue, tags: record.tags
            )
            var updated = record
            updated.zoteroVersion = newVersion
            AnnotationStore.shared.update(updated)
            status = .idle
        } catch ZoteroError.conflict {
            await retryUpdateAfterConflict(record: record, key: key)
        } catch {
            handle(error)
        }
    }

    func pushDelete(_ record: PDFHighlightAnnotation) async {
        guard let client, let userID else { return }
        guard let key = record.zoteroItemKey, let version = record.zoteroVersion else { return }
        status = .syncing
        do {
            try await client.deleteAnnotation(userID: userID, key: key, version: version)
            status = .idle
        } catch ZoteroError.conflict {
            status = .idle // already changed/gone remotely either way; next reconcile settles it
        } catch {
            handle(error)
        }
    }

    /// One retry with the server's current version on a 412, per the plan: if it
    /// conflicts again, drop it and let the normal inbound reconcile settle things
    /// rather than building bespoke conflict UI.
    private func retryUpdateAfterConflict(record: PDFHighlightAnnotation, key: String) async {
        guard let client, let userID else { return }
        do {
            let fresh = try await client.fetchAnnotation(userID: userID, key: key)
            let newVersion = try await client.updateAnnotation(
                userID: userID, key: key, version: fresh.version, comment: record.comment, color: record.color,
                type: record.kind.rawValue, tags: record.tags
            )
            var updated = record
            updated.zoteroVersion = newVersion
            AnnotationStore.shared.update(updated)
            status = .idle
        } catch {
            handle(error)
        }
    }

    // MARK: - Inbound

    /// Library-wide (not per-document) — guarded against overlapping calls from
    /// multiple open windows' `bootstrap()` and streaming `topicUpdated` events.
    func reconcileLibrary() async {
        guard !isReconciling, let client, let userID else { return }
        isReconciling = true
        defer { isReconciling = false }
        status = .syncing
        do {
            let sinceVersion = lastLibraryVersion
            let (changed, newVersion) = try await client.fetchChangedAnnotations(userID: userID, since: sinceVersion)
            for item in changed { applyRemote(item) }
            // Deletions never appear in the regular items fetch above — they only
            // ever show up here (confirmed against the live API this session).
            let deletedKeys = try await client.fetchDeletedItemKeys(userID: userID, since: sinceVersion)
            if !deletedKeys.isEmpty {
                let store = AnnotationStore.shared
                for key in deletedKeys {
                    if let existing = store.all.first(where: { $0.zoteroItemKey == key }) {
                        store.delete(existing.id)
                    }
                }
            }
            lastLibraryVersion = newVersion
            await backfillUnpushedRecords(client: client, userID: userID)
            status = .idle
        } catch {
            handle(error)
        }
    }

    /// Ids touched by the most recent `applyRemote` pass — `PDFVisualView`'s
    /// `Coordinator` watches this to close an open edit popover rather than let it
    /// silently clobber a remote change on "Done".
    @Published private(set) var lastRemoteChangeIDs: Set<UUID> = []

    private func applyRemote(_ item: ZoteroAnnotationItem) {
        let store = AnnotationStore.shared
        if let existing = store.all.first(where: { $0.zoteroItemKey == item.key }) {
            var updated = existing
            updated.comment = item.data.annotationComment ?? updated.comment
            updated.color = item.data.annotationColor ?? updated.color
            updated.kind = item.data.annotationType.flatMap(PDFAnnotationKind.init(rawValue:)) ?? updated.kind
            updated.tags = item.data.tags?.map(\.tag) ?? updated.tags
            updated.zoteroVersion = item.version
            store.update(updated)
            lastRemoteChangeIDs.insert(existing.id)
            return
        }
        guard let parentKey = item.data.parentItem,
              let link = ZoteroLinkStore.shared.link(forAttachmentItemKey: parentKey),
              let position = item.position else { return }
        let record = PDFHighlightAnnotation(
            documentKey: link.documentKey,
            pageIndex: position.pageIndex,
            matchText: item.data.annotationText ?? "",
            comment: item.data.annotationComment ?? "",
            color: item.data.annotationColor ?? HighlightSwatches.defaultHex,
            kind: item.data.annotationType.flatMap(PDFAnnotationKind.init(rawValue:)) ?? .highlight,
            tags: item.data.tags?.map(\.tag) ?? [],
            rects: position.rects,
            zoteroItemKey: item.key,
            zoteroVersion: item.version,
            pageLabel: item.data.annotationPageLabel
        )
        store.add(record)
        lastRemoteChangeIDs.insert(record.id)
    }

    /// First-sync migration: any local record predating this feature (`zoteroItemKey
    /// == nil`) whose document is now linked gets created remotely.
    private func backfillUnpushedRecords(client: ZoteroClient, userID: Int) async {
        let unpushed = AnnotationStore.shared.all.filter { $0.zoteroItemKey == nil }
        guard !unpushed.isEmpty else { return }
        let byDoc = Dictionary(grouping: unpushed, by: { $0.documentKey })
        for (docKey, records) in byDoc {
            guard let link = ZoteroLinkStore.shared.link(for: docKey) else { continue }
            for chunkStart in stride(from: 0, to: records.count, by: 50) {
                let chunk = Array(records[chunkStart..<min(chunkStart + 50, records.count)])
                let payloads = chunk.map { $0.zoteroCreatePayload(parentItem: link.attachmentItemKey) }
                guard let result = try? await client.createAnnotations(userID: userID, payloads: payloads) else { continue }
                for (i, record) in chunk.enumerated() {
                    if let created = result.successful[String(i)] {
                        var updated = record
                        updated.zoteroItemKey = created.key
                        updated.zoteroVersion = created.version
                        AnnotationStore.shared.update(updated)
                    }
                }
            }
        }
    }

    private func handle(_ error: Error) {
        switch error {
        case ZoteroError.offline:
            status = .offline
        case ZoteroError.unauthorized:
            status = .error("Zotero rejected the API key")
        case ZoteroError.rateLimited(let retryAfter):
            let delay = retryAfter ?? 5
            status = .error("Rate limited, retrying")
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await reconcileLibrary()
            }
        default:
            status = .error(error.localizedDescription)
        }
    }
}
