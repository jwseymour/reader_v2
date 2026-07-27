import Foundation

enum DotEnv {
    /// Loads KEY=VALUE pairs from the first existing `.env` candidate.
    /// Does not override variables already present in the process environment.
    @discardableResult
    static func load() -> [String: String] {
        var loaded: [String: String] = [:]
        guard let url = firstExistingURL() else { return loaded }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return loaded }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            loaded[key] = value
            if ProcessInfo.processInfo.environment[key] == nil {
                setenv(key, value, 0)
            }
        }
        return loaded
    }

    static func value(_ key: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
            return env
        }
        let loaded = load()
        let v = loaded[key]
        return (v?.isEmpty == false) ? v : nil
    }

    private static func firstExistingURL() -> URL? {
        var candidates: [URL] = []

        // Next to the app / project when launched from Xcode
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".env"))
        candidates.append(cwd.appendingPathComponent("../.env"))
        candidates.append(cwd.appendingPathComponent("../../.env"))

        // Repo-style locations relative to the bundle
        let bundle = Bundle.main.bundleURL
        candidates.append(bundle.appendingPathComponent(".env"))
        candidates.append(bundle.deletingLastPathComponent().appendingPathComponent(".env"))
        // …/AccessibleReader.app/Contents/MacOS → walk up looking for reader_v2/.env
        var walk = bundle
        for _ in 0..<8 {
            walk = walk.deletingLastPathComponent()
            candidates.append(walk.appendingPathComponent(".env"))
            candidates.append(walk.appendingPathComponent("reader_v2/.env"))
        }

        // Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("AccessibleReader/.env"))
        }

        // Workspace path used in development
        candidates.append(URL(fileURLWithPath: NSString(string: "~/jack_code/reader_v2/.env").expandingTildeInPath))

        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
