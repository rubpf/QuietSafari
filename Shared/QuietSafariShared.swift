import Foundation
import os

/// Values shared by the macOS app, the Safari web extension, and the content blocker.
/// The app group identifier is read from the built Info.plist so it matches the
/// entitlement after Xcode substitutes the team prefix.
enum QuietSafariShared {
    static let appGroupInfoKey = "QuietSafariAppGroup"
    static let appGroupSuffix = "com.quietsafari.shared"
    static let settingsFileName = "settings.json"
    static let statsFileName = "stats.json"
    static let rulesFileName = "blockerList.json"
    static let privacyRulesFileName = "privacyList.json"
    static let russianRulesFileName = "russianList.json"
    static let bundledFilterVersion = 4

    static let log = Logger(subsystem: "com.quietsafari.macos", category: "shared")

    static var appGroupID: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.contains("$") {
            return appGroupSuffix
        }
        return value
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Prefer rules written by the app (allowlist already applied). Fall back to the copy in the bundle.
    static func resolvedRulesURL(named name: String, bundled: URL?) -> URL? {
        if let url = fileURL(name), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return bundled
    }

    static func readRules(named name: String) -> Data? {
        guard let url = fileURL(name) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func readSettings() -> QuietSafariSettings {
        readJSON(settingsFileName, fallback: .default)
    }

    static func writeCurrentHost(_ host: String) {
        guard let url = fileURL("current-host.txt") else {
            return
        }
        try? Data(host.utf8).write(to: url, options: .atomic)
    }

    static func readCurrentHost() -> String {
        guard let url = fileURL("current-host.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func readStats() -> QuietSafariStats {
        readJSON(statsFileName, fallback: .default)
    }

    @discardableResult
    static func writeSettings(_ settings: QuietSafariSettings) -> Bool {
        writeJSON(settings, name: settingsFileName)
    }

    @discardableResult
    static func writeStats(_ stats: QuietSafariStats) -> Bool {
        writeJSON(stats, name: statsFileName)
    }

    @discardableResult
    static func writeRules(_ data: Data, named name: String) -> Bool {
        guard let url = fileURL(name) else {
            log.error("App group container is unavailable; rules were not written")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("Failed to write rules: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Safari asks a content blocker for rules only while that extension is switched on.
    /// Each blocker writes its own file so the two extensions cannot overwrite each other.
    static func markRulesServed(named name: String) {
        guard let url = fileURL("served-" + name) else {
            return
        }
        let body = ["at": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func lastServed(named name: String) -> TimeInterval? {
        guard let url = fileURL("served-" + name),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["at"] as? NSNumber else {
            return nil
        }
        return number.doubleValue
    }

    private static func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name)
    }

    private static func readJSON<T: Decodable>(_ name: String, fallback: T) -> T {
        guard let url = fileURL(name),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return fallback
        }
        return value
    }

    private static func writeJSON<T: Encodable>(_ value: T, name: String) -> Bool {
        guard let url = fileURL(name) else {
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("Failed to write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

struct QuietSafariSettings: Codable, Equatable {
    var blockingEnabled: Bool
    var allowlist: [String]
    var blockCookieNotices: Bool
    var hideDockIcon: Bool

    static let `default` = QuietSafariSettings(
        blockingEnabled: true,
        allowlist: [],
        blockCookieNotices: false,
        hideDockIcon: false
    )

    init(blockingEnabled: Bool, allowlist: [String], blockCookieNotices: Bool = false, hideDockIcon: Bool = false) {
        self.blockingEnabled = blockingEnabled
        self.allowlist = allowlist
        self.blockCookieNotices = blockCookieNotices
        self.hideDockIcon = hideDockIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockingEnabled = try container.decodeIfPresent(Bool.self, forKey: .blockingEnabled) ?? true
        allowlist = try container.decodeIfPresent([String].self, forKey: .allowlist) ?? []
        blockCookieNotices = try container.decodeIfPresent(Bool.self, forKey: .blockCookieNotices) ?? false
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
    }
}

struct QuietSafariStats: Codable, Equatable {
    var blockedCount: Int

    static let `default` = QuietSafariStats(blockedCount: 0)
}

enum QuietSafariBridge {
    /// Reply to a Safari web extension native message. The payload is a property list.
    static func reply(to message: [String: Any]?) -> [String: Any] {
        let type = message?["type"] as? String ?? "getState"
        if type == "activeHost" {
            let host = (message?["host"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !host.isEmpty {
                QuietSafariShared.writeCurrentHost(host)
            }
            return statePayload()
        }
        if type == "setBlockedCount" {
            let count = intValue(message?["blockedCount"])
            let wrote = QuietSafariShared.writeStats(QuietSafariStats(blockedCount: max(0, count)))
            var payload = statePayload()
            payload["wroteStats"] = wrote
            return payload
        }
        return statePayload()
    }

    static func statePayload() -> [String: Any] {
        let settings = QuietSafariShared.readSettings()
        let stats = QuietSafariShared.readStats()
        return [
            "ok": true,
            "appGroup": QuietSafariShared.containerURL != nil,
            "blockingEnabled": settings.blockingEnabled,
            "allowlist": settings.allowlist,
            "blockCookieNotices": settings.blockCookieNotices,
            "blockedCount": stats.blockedCount,
        ]
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 0
    }
}
