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
    private let manualKeyKey = "openAIKeyOverridesEnv"
    private let zoteroKeychainAccount = "zotero-api-key"

    /// Where the active OpenAI key came from — surfaced in the inspector so a stale
    /// Keychain entry can never silently shadow the key in `.env.local`.
    enum APIKeySource: Equatable {
        case none
        case envFile(String)
        case keychain

        var label: String {
            switch self {
            case .none: return "No key configured"
            case .envFile(let path): return "From \((path as NSString).lastPathComponent)"
            case .keychain: return "From Keychain"
            }
        }
    }

    @Published private(set) var apiKeySource: APIKeySource = .none
    /// Set when OpenAI rejects the key, so the UI can say so instead of silently
    /// falling back to macOS voices.
    @Published var apiKeyRejected = false

    private var isBootstrapping = true

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
        didSet {
            guard !isBootstrapping, openAIAPIKey != oldValue else { return }
            saveAPIKey(openAIAPIKey)
            apiKeyRejected = false
            // A key typed by hand that differs from `.env` is an explicit override;
            // remember that so it survives relaunch instead of losing to the file.
            let envKey = DotEnv.fileValue("OPENAI_API_KEY")
            let overrides = !openAIAPIKey.isEmpty && openAIAPIKey != envKey
            defaults.set(overrides, forKey: manualKeyKey)
            if openAIAPIKey.isEmpty {
                apiKeySource = .none
            } else if overrides {
                apiKeySource = .keychain
            } else {
                apiKeySource = .envFile(DotEnv.loadedPath ?? ".env")
            }
        }
    }

    /// From .env `OPENAI_TTS_MODEL`, defaulting to high-quality speech.
    @Published var openAITTSModel: String = "tts-1-hd"

    /// Keychain-only — deliberately does NOT follow `openAIAPIKey`'s `.env`-can-override
    /// pattern. That dual-source design exists for local dev convenience, but this repo
    /// already had one `.env` file accidentally committed and a key revoked over it; a
    /// second credential doesn't need to repeat that surface.
    @Published var zoteroAPIKey: String = "" {
        didSet {
            guard !isBootstrapping, zoteroAPIKey != oldValue else { return }
            saveSecret(zoteroAPIKey, account: zoteroKeychainAccount)
            zoteroAPIKeyRejected = false
            ZoteroSyncStore.shared.configure(apiKey: zoteroAPIKey)
        }
    }
    /// Set when Zotero rejects the key (401), mirroring `apiKeyRejected`.
    @Published var zoteroAPIKeyRejected = false

    private init() {
        DotEnv.load()

        if let s = defaults.string(forKey: preferredKey) {
            preferredPresetID = UUID(uuidString: s)
        } else {
            preferredPresetID = nil
        }
        hasCompletedFirstRun = defaults.bool(forKey: firstRunKey)
        if let s = defaults.string(forKey: compareBKey) {
            comparePresetBID = UUID(uuidString: s)
        }

        // `.env` wins over the Keychain unless a key was typed in by hand. The old
        // order let a revoked Keychain entry shadow a fresh key in the file forever.
        let keychain = loadAPIKey()
        let envKey = DotEnv.fileValue("OPENAI_API_KEY")
        let manualOverride = defaults.bool(forKey: manualKeyKey)

        if manualOverride, !keychain.isEmpty {
            openAIAPIKey = keychain
            apiKeySource = .keychain
        } else if let envKey {
            openAIAPIKey = envKey
            apiKeySource = .envFile(DotEnv.loadedPath ?? ".env")
        } else if !keychain.isEmpty {
            openAIAPIKey = keychain
            apiKeySource = .keychain
        } else {
            openAIAPIKey = ""
            apiKeySource = .none
        }

        if let model = DotEnv.value("OPENAI_TTS_MODEL"), !model.isEmpty {
            openAITTSModel = model
        }
        zoteroAPIKey = loadSecret(account: zoteroKeychainAccount)
        isBootstrapping = false
        ZoteroSyncStore.shared.configure(apiKey: zoteroAPIKey)
    }

    /// Called when OpenAI rejects the current key (401). If a *different* key is
    /// sitting in `.env`, switch to it and report that a retry is worthwhile.
    @discardableResult
    func handleRejectedKey() -> Bool {
        apiKeyRejected = true
        guard case .keychain = apiKeySource,
              let envKey = DotEnv.fileValue("OPENAI_API_KEY"),
              envKey != openAIAPIKey else {
            return false
        }
        defaults.set(false, forKey: manualKeyKey)
        openAIAPIKey = envKey
        apiKeySource = .envFile(DotEnv.loadedPath ?? ".env")
        apiKeyRejected = false
        return true
    }

    private func saveAPIKey(_ key: String) {
        saveSecret(key, account: keychainAccount)
    }

    private func loadAPIKey() -> String {
        loadSecret(account: keychainAccount)
    }

    private func saveSecret(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private func loadSecret(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
