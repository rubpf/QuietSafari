import AppKit
import Foundation
import SafariServices

/// Settings the owner sees. The app is the source of truth for the switch and the allowlist.
/// The web extension is the source of truth for the counter it can actually observe.
final class SettingsStore: ObservableObject {
    @Published var blockingEnabled: Bool
    @Published var allowlist: [String]
    @Published var blockedCount: Int
    @Published var appGroupAvailable: Bool
    @Published var appGroupID: String
    @Published var contentBlockerEnabled: Bool?
    @Published var privacyBlockerEnabled: Bool?
    @Published var webExtensionEnabled: Bool?
    @Published var filterSummary = ""
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var isBusy = false

    private let server = TestPageServer()
    private var timer: Timer?
    private var started = false
    private var pollTick = 0
    private var reloadGeneration = 0
    private let processStartedAt = Date().timeIntervalSince1970
    private var contentBlockerAPIConfirmed = false
    private var privacyAPIConfirmed = false
    private var contentBlockerReloadOK: Bool?
    private var privacyReloadOK: Bool?

    deinit {
        timer?.invalidate()
    }

    init() {
        let settings = QuietSafariShared.readSettings()
        blockingEnabled = settings.blockingEnabled
        allowlist = settings.allowlist
        blockedCount = QuietSafariShared.readStats().blockedCount
        appGroupAvailable = QuietSafariShared.containerURL != nil
        appGroupID = QuietSafariShared.appGroupID
    }

    var versionText: String {
        if !filterSummary.isEmpty {
            return filterSummary
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
        return "Версия \(version)."
    }

    func start() {
        if started {
            return
        }
        started = true
        persistAndReload(userInitiated: false)
        refreshExtensionStates()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func setBlockingEnabled(_ enabled: Bool) {
        let previous = blockingEnabled
        blockingEnabled = enabled
        persistAndReload(userInitiated: true) { [weak self] in
            self?.blockingEnabled = previous
        }
    }

    func addSite(_ raw: String) -> String? {
        guard let domain = DomainNormalizer.normalize(raw) else {
            return "Не получилось распознать адрес. Напишите его как example.com — без https и без пути."
        }
        if allowlist.contains(domain) {
            return "Этот сайт уже в списке."
        }
        let previous = allowlist
        allowlist.append(domain)
        allowlist.sort()
        persistAndReload(userInitiated: true) { [weak self] in
            self?.allowlist = previous
        }
        return nil
    }

    func removeSite(_ domain: String) {
        let previous = allowlist
        allowlist.removeAll { $0 == domain }
        persistAndReload(userInitiated: true) { [weak self] in
            self?.allowlist = previous
        }
    }

    func reapplyRules() {
        isBusy = true
        statusMessage = "Скачиваю EasyList и EasyPrivacy…"
        statusIsError = false
        FilterLibrary.download { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(let meta):
                self.filterSummary = FilterLibrary.summary(meta)
                self.persistAndReload(userInitiated: true)
            case .failure(let error):
                self.isBusy = false
                self.statusMessage = error.localizedDescription
                self.statusIsError = true
            }
        }
    }

    func openTestPage() {
        guard let url = Bundle.main.url(forResource: "TestPage", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = TestPageError.missingPage.localizedDescription
            statusIsError = true
            return
        }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            do {
                let pageURL = try self.server.start(html: html)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.openInSafari(pageURL)
                    self.statusMessage = "Открыл проверочную страницу в Safari. Если macOS спросил про входящие соединения, нажмите «Разрешить» — сервер слушает только этот компьютер."
                    self.statusIsError = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                    self.statusIsError = true
                }
            }
        }
    }

    private func poll() {
        refreshStats()
        pollTick += 1
        if pollTick % 3 == 0 {
            refreshExtensionStates()
        }
    }

    private func refreshStats() {
        appGroupAvailable = QuietSafariShared.containerURL != nil
        appGroupID = QuietSafariShared.appGroupID
        let count = QuietSafariShared.readStats().blockedCount
        if count != blockedCount {
            blockedCount = count
        }
    }

    private func refreshExtensionStates() {
        let adsID = QuietSafariIdentity.contentBlockerBundleID
        let privacyID = QuietSafariIdentity.privacyBundleID
        let extensionID = QuietSafariIdentity.webExtensionBundleID
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: adsID) { state, _ in
            DispatchQueue.main.async {
                let api = state.map(\.isEnabled)
                var confirmed = self.contentBlockerAPIConfirmed
                self.contentBlockerEnabled = self.decide(
                    api: api,
                    servedName: QuietSafariShared.rulesFileName,
                    reloadOK: self.contentBlockerReloadOK,
                    sawAPITrue: &confirmed
                )
                self.contentBlockerAPIConfirmed = confirmed
            }
        }
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: privacyID) { state, _ in
            DispatchQueue.main.async {
                let api = state.map(\.isEnabled)
                var confirmed = self.privacyAPIConfirmed
                self.privacyBlockerEnabled = self.decide(
                    api: api,
                    servedName: QuietSafariShared.privacyRulesFileName,
                    reloadOK: self.privacyReloadOK,
                    sawAPITrue: &confirmed
                )
                self.privacyAPIConfirmed = confirmed
            }
        }
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionID) { state, _ in
            DispatchQueue.main.async {
                if let state {
                    self.webExtensionEnabled = state.isEnabled
                }
            }
        }
    }

    /// SFContentBlockerState.isEnabled has been observed stuck on false while Safari's
    /// own checkbox is on. A successful reload, or Safari asking the extension for rules,
    /// is treated as enabled until the API itself has reported true at least once.
    private func decide(api: Bool?, servedName: String, reloadOK: Bool?, sawAPITrue: inout Bool) -> Bool? {
        if api == true {
            sawAPITrue = true
            return true
        }
        if sawAPITrue {
            return api
        }
        let servedAt = QuietSafariShared.lastServed(named: servedName) ?? 0
        if servedAt >= processStartedAt || reloadOK == true {
            return true
        }
        if api == false || reloadOK == false {
            return false
        }
        return nil
    }

    private func persistAndReload(userInitiated: Bool, revert: (() -> Void)? = nil) {
        let settings = QuietSafariSettings(blockingEnabled: blockingEnabled, allowlist: allowlist)
        isBusy = true
        reloadGeneration += 1
        let generation = reloadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let meta = FilterLibrary.prepare()
            let wroteSettings = QuietSafariShared.writeSettings(settings)
            let wroteRules = FilterLibrary.apply(settings: settings)
            DispatchQueue.main.async {
                guard generation == self.reloadGeneration else {
                    return
                }
                self.appGroupAvailable = QuietSafariShared.containerURL != nil
                self.appGroupID = QuietSafariShared.appGroupID
                if meta.adCount > 0 {
                    self.filterSummary = FilterLibrary.summary(meta)
                }
                guard wroteSettings, wroteRules else {
                    revert?()
                    self.isBusy = false
                    self.statusMessage = self.appGroupAvailable
                        ? "Не удалось записать правила в общую папку."
                        : "Общая папка недоступна. Выберите одну и ту же команду (Team) у всех целей и нажмите Run ещё раз. Встроенные списки при этом всё равно отдаются Safari."
                    self.statusIsError = true
                    return
                }
                self.reloadBlockers(generation: generation, userInitiated: userInitiated)
            }
        }
    }

    private func reloadBlockers(generation: Int, userInitiated: Bool) {
        let group = DispatchGroup()
        let outcome = ReloadOutcome()
        group.enter()
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: QuietSafariIdentity.contentBlockerBundleID) { error in
            outcome.ads = error
            group.leave()
        }
        group.enter()
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: QuietSafariIdentity.privacyBundleID) { error in
            outcome.privacy = error
            group.leave()
        }
        group.notify(queue: .main) {
            guard generation == self.reloadGeneration else {
                return
            }
            self.isBusy = false
            self.contentBlockerReloadOK = outcome.ads == nil
            self.privacyReloadOK = outcome.privacy == nil
            self.refreshExtensionStates()
            guard userInitiated else {
                return
            }
            if outcome.ads != nil && outcome.privacy != nil {
                self.statusMessage = "Не удалось применить правила: \(outcome.ads?.localizedDescription ?? ""). Если расширение выключено в Safari, включите его и нажмите кнопку ещё раз."
                self.statusIsError = true
            } else if outcome.ads != nil || outcome.privacy != nil {
                let name = outcome.ads != nil ? "QuietSafari Content Blocker" : "QuietSafari Privacy"
                self.statusMessage = "\(name) не принял правила. Включите его в Safari → Настройки → Дополнения и нажмите кнопку ещё раз."
                self.statusIsError = true
            } else {
                self.statusMessage = "Правила применены. Обновите уже открытые страницы в Safari."
                self.statusIsError = false
            }
        }
    }

    private func openInSafari(_ url: URL) {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    self.statusMessage = "Не удалось открыть Safari: \(error.localizedDescription)"
                    self.statusIsError = true
                }
            }
        }
    }
}

private final class ReloadOutcome {
    var ads: Error?
    var privacy: Error?
}

enum QuietSafariIdentity {
    static let defaultWebExtensionBundleID = "com.quietsafari.macos.extension"
    static let defaultContentBlockerBundleID = "com.quietsafari.macos.content-blocker"
    static let defaultPrivacyBundleID = "com.quietsafari.macos.privacy"

    static var webExtensionBundleID: String {
        embedded("QuietSafariExtension.appex", fallback: defaultWebExtensionBundleID)
    }

    static var contentBlockerBundleID: String {
        embedded("QuietSafariContentBlocker.appex", fallback: defaultContentBlockerBundleID)
    }

    static var privacyBundleID: String {
        embedded("QuietSafariPrivacy.appex", fallback: defaultPrivacyBundleID)
    }

    /// The built appex Info.plist is the identifier Safari registered. The host
    /// plist can disagree when a build setting fails to expand.
    private static func embedded(_ appexName: String, fallback: String) -> String {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(appexName),
              let identifier = Bundle(url: url)?.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              !identifier.contains("$") else {
            return fallback
        }
        return identifier
    }
}
