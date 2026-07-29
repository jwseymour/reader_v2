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
        return fileValue(key)
    }

    /// Value straight from the `.env` file, ignoring the process environment.
    /// `load()` mirrors file values into the process environment via `setenv`,
    /// so this is the only way to tell where a value actually came from.
    static func fileValue(_ key: String) -> String? {
        let v = load()[key]
        return (v?.isEmpty == false) ? v : nil
    }

    /// Path of the file that `load()` last read, for showing the key's origin in the UI.
    private(set) static var loadedPath: String?

    /// `.env.local` takes precedence over `.env` in the same directory, matching the
    /// usual convention: `.env` is the shared/checked-in shape, `.env.local` is yours.
    private static let fileNames = [".env.local", ".env"]

    private static func firstExistingURL() -> URL? {
        var directories: [URL] = []

        // Next to the app / project when launched from Xcode
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        directories.append(cwd)
        directories.append(cwd.appendingPathComponent(".."))
        directories.append(cwd.appendingPathComponent("../.."))

        // Repo-style locations relative to the bundle
        let bundle = Bundle.main.bundleURL
        directories.append(bundle)
        directories.append(bundle.deletingLastPathComponent())
        // …/AccessibleReader.app/Contents/MacOS → walk up looking for the repo root
        var walk = bundle
        for _ in 0..<8 {
            walk = walk.deletingLastPathComponent()
            directories.append(walk)
            directories.append(walk.appendingPathComponent("reader_v2"))
        }

        // Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(appSupport.appendingPathComponent("AccessibleReader"))
        }

        // Workspace path used in development
        directories.append(URL(fileURLWithPath: NSString(string: "~/jack_code/reader_v2").expandingTildeInPath))

        let fm = FileManager.default
        for dir in directories {
            for name in fileNames {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) {
                    loadedPath = url.standardizedFileURL.path
                    return url
                }
            }
        }
        return nil
    }
}
