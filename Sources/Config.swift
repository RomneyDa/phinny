import Foundation
import Yams

/// Global Phinny paths. Everything lives under ~/.phinny:
///   ~/.phinny/config.yaml     - non-sensitive settings only
///   ~/.phinny/phinny.sqlite   - synced account + transaction data
///
/// The SimpleFIN access URL (which embeds bank-read credentials) is NOT stored
/// here - it lives in the macOS Keychain (see Keychain.swift). The directory is
/// still created with 0700. Phinny is intentionally NOT sandboxed so it can use
/// this shared home-directory location (see the entitlements files).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = home.appendingPathComponent(".phinny", isDirectory: true)
    static let configFile = configDir.appendingPathComponent("config.yaml")
    static let databaseFile = configDir.appendingPathComponent("phinny.sqlite")
    /// Writable copy of the bundled demo database, used when no account is connected.
    static let demoDatabaseFile = configDir.appendingPathComponent("phinny-demo.sqlite")

    /// Create ~/.phinny (0700) if needed. Safe to call repeatedly.
    static func ensureConfigDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir.path) {
            try fm.createDirectory(
                at: configDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}

/// The on-disk YAML config. Codable maps 1:1 to config.yaml. Holds only
/// non-sensitive settings; credentials live in the Keychain.
struct Config: Codable, Equatable {
    var sync: Sync = Sync()

    struct Sync: Codable, Equatable {
        /// Auto-sync on launch only if the last sync is older than this. Guards
        /// the provider's ~24 requests/day budget against repeated launches.
        var minIntervalHours: Int = 6
        /// How far back to request transactions on each sync.
        var historyDays: Int = 365

        enum CodingKeys: String, CodingKey {
            case minIntervalHours = "min_interval_hours"
            case historyDays = "history_days"
        }
    }
}

/// Loads/saves Config to ~/.phinny/config.yaml.
enum ConfigStore {
    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let text = String(data: data, encoding: .utf8),
              let config = try? YAMLDecoder().decode(Config.self, from: text)
        else {
            return Config()  // first run / unreadable → defaults
        }
        return config
    }

    static func save(_ config: Config) throws {
        try Paths.ensureConfigDir()
        let yaml = try YAMLEncoder().encode(config)
        try yaml.write(to: Paths.configFile, atomically: true, encoding: .utf8)
        // Tighten permissions - the access URL is a credential.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.configFile.path
        )
    }
}
