import Foundation
import Security

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private let preferredKey = "preferredPresetID"
    private let firstRunKey = "hasCompletedFirstRun"
    private let compareBKey = "comparePresetBID"
    private let keychainService = "com.jack.AccessibleReaderV2"
    private let keychainAccount = "openai-api-key"

    @Published var preferredPresetID: UUID? {
        didSet { defaults.set(preferredPresetID?.uuidString, forKey: preferredKey) }
    }

    @Published var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: firstRunKey) }
    }

    @Published var comparePresetBID: UUID? {
        didSet { defaults.set(comparePresetBID?.uuidString, forKey: compareBKey) }
    }

    @Published var openAIAPIKey: String = "" {
        didSet { saveAPIKey(openAIAPIKey) }
    }

    private init() {
        if let s = defaults.string(forKey: preferredKey) {
            preferredPresetID = UUID(uuidString: s)
        } else {
            preferredPresetID = nil
        }
        hasCompletedFirstRun = defaults.bool(forKey: firstRunKey)
        if let s = defaults.string(forKey: compareBKey) {
            comparePresetBID = UUID(uuidString: s)
        }
        openAIAPIKey = loadAPIKey()
    }

    private func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
