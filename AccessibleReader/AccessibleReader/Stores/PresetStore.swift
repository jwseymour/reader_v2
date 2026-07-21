import Foundation
import Combine

@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    @Published private(set) var presets: [ReadingPreset] = []
    @Published var activePresetID: UUID?

    private let fileURL: URL
    private var cancellables = Set<AnyCancellable>()

    var activePreset: ReadingPreset {
        get {
            if let id = activePresetID, let p = presets.first(where: { $0.id == id }) {
                return p
            }
            return presets.first ?? .starter
        }
        set {
            upsert(newValue)
            activePresetID = newValue.id
        }
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AccessibleReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("presets.json")
        load()
        if let preferred = SettingsStore.shared.preferredPresetID,
           presets.contains(where: { $0.id == preferred }) {
            activePresetID = preferred
        } else {
            activePresetID = presets.first?.id
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ReadingPreset].self, from: data) else {
            presets = []
            return
        }
        presets = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ preset: ReadingPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        save()
    }

    func create(named name: String, basedOn: ReadingPreset? = nil) -> ReadingPreset {
        var p = basedOn ?? ReadingPreset.starter
        p.id = UUID()
        p.name = name
        p.shortcutSlot = nextFreeSlot()
        upsert(p)
        return p
    }

    func duplicate(_ preset: ReadingPreset) -> ReadingPreset {
        create(named: preset.name + " Copy", basedOn: preset)
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id {
            activePresetID = presets.first?.id
        }
        if SettingsStore.shared.preferredPresetID == id {
            SettingsStore.shared.preferredPresetID = activePresetID
        }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard var p = presets.first(where: { $0.id == id }) else { return }
        p.name = name
        upsert(p)
    }

    func reset(_ id: UUID) {
        guard let existing = presets.first(where: { $0.id == id }) else { return }
        var fresh = ReadingPreset.starter
        fresh.id = existing.id
        fresh.name = existing.name
        fresh.shortcutSlot = existing.shortcutSlot
        upsert(fresh)
    }

    func activate(_ id: UUID) {
        guard presets.contains(where: { $0.id == id }) else { return }
        activePresetID = id
    }

    func activateSlot(_ slot: Int) {
        if let p = presets.first(where: { $0.shortcutSlot == slot }) {
            activate(p.id)
        } else if presets.indices.contains(slot - 1) {
            activate(presets[slot - 1].id)
        }
    }

    func updateActive(_ mutate: (inout ReadingPreset) -> Void) {
        var p = activePreset
        mutate(&p)
        upsert(p)
        activePresetID = p.id
    }

    func exportPreset(_ id: UUID) -> Data? {
        guard let p = presets.first(where: { $0.id == id }) else { return nil }
        return try? JSONEncoder().encode(p)
    }

    func importPreset(from data: Data) throws -> ReadingPreset {
        var p = try JSONDecoder().decode(ReadingPreset.self, from: data)
        p.id = UUID()
        p.shortcutSlot = nextFreeSlot()
        upsert(p)
        return p
    }

    private func nextFreeSlot() -> Int? {
        let used = Set(presets.compactMap(\.shortcutSlot))
        for i in 1...9 where !used.contains(i) { return i }
        return nil
    }
}
