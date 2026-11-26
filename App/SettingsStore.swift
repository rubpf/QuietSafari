import AppKit
import Foundation
import SafariServices

/// Settings the owner sees. The app is the source of truth for the switch and the allowlist.
/// The web extension is the source of truth for the counter it can actually observe.
final class SettingsStore: ObservableObject {
    @Published var blockingEnabled: Bool
    @Published var allowlist: [String]
    @Published var blockCookieNotices: Bool
    @Published var blockedCount: Int
    @Published var appGroupAvailable: Bool
    @Published var appGroupID: String
    @Published var contentBlockerEnabled: Bool?
    @Published var privacyBlockerEnabled: Bool?
    @Published var russianBlockerEnabled: Bool?
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
    private var russianAPIConfirmed = false
    private var contentBlockerReloadOK: Bool?
    private var privacyReloadOK: Bool?
    private var russianReloadOK: Bool?
    private var statusTimedOut = false

    deinit {
        timer?.invalidate()
    }

    init() {
        let settings = QuietSafariShared.readSettings()
        blockingEnabled = settings.blockingEnabled
        allowlist = settings.allowlist
        blockCookieNotices = settings.blockCookieNotices
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

    func refreshNow() {
        refreshExtensionStates()
    }

    func setBlockCookieNotices(_ enabled: Bool) {
        let previous = blockCookieNotices
        blockCookieNotices = enabled
        persistAndReload(userInitiated: true) { [weak self] in
            self?.blockCookieNotices = previous
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
        statusMessage = "Скачиваю EasyList, EasyPrivacy и RU AdList…"
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
        settleUnknownStates()
    }

    /// Safari sometimes never calls back for a large content blocker, which used to
    /// leave the row on "ещё не проверено" forever. After a short wait, say it is off
    /// and point at the duplicate-extension cleanup.
    private func settleUnknownStates() {
        guard !statusTimedOut else { return }
        guard Date().timeIntervalSince1970 - processStartedAt > 12 else { return }
        let unknown = contentBlockerEnabled == nil || privacyBlockerEnabled == nil || russianBlockerEnabled == nil
        guard unknown else { return }
        statusTimedOut = true
        if contentBlockerEnabled == nil { contentBlockerEnabled = false }
        if privacyBlockerEnabled == nil { privacyBlockerEnabled = false }
        if russianBlockerEnabled == nil { russianBlockerEnabled = false }
        statusMessage = "Safari не ответил про одно из расширений. Закройте Safari, удалите старые копии QuietSafari (раздел README «Две копии одного расширения») и нажмите Run."
        statusIsError = true
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
        let russianID = QuietSafariIdentity.russianBundleID
        let extensionID = QuietSafariIdentity.webExtensionBundleID
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: adsID) { state, error in
            DispatchQueue.main.async {
                var confirmed = self.contentBlockerAPIConfirmed
                self.contentBlockerEnabled = self.decide(
                    api: Self.apiFlag(state: state, error: error),
                    servedName: QuietSafariShared.rulesFileName,
                    reloadOK: self.contentBlockerReloadOK,
                    sawAPITrue: &confirmed
                )
                self.contentBlockerAPIConfirmed = confirmed
            }
        }
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: privacyID) { state, error in
            DispatchQueue.main.async {
                var confirmed = self.privacyAPIConfirmed
                self.privacyBlockerEnabled = self.decide(
                    api: Self.apiFlag(state: state, error: error),
                    servedName: QuietSafariShared.privacyRulesFileName,
                    reloadOK: self.privacyReloadOK,
                    sawAPITrue: &confirmed
                )
                self.privacyAPIConfirmed = confirmed
            }
        }
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: russianID) { state, error in
            DispatchQueue.main.async {
                var confirmed = self.russianAPIConfirmed
                self.russianBlockerEnabled = self.decide(
                    api: Self.apiFlag(state: state, error: error),
                    servedName: QuietSafariShared.russianRulesFileName,
                    reloadOK: self.russianReloadOK,
                    sawAPITrue: &confirmed
                )
                self.russianAPIConfirmed = confirmed
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
    private static func apiFlag(state: SFContentBlockerState?, error: Error?) -> Bool? {
        if let state {
            return state.isEnabled
        }
        if error != nil {
            return false
        }
        return nil
    }

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
        let settings = QuietSafariSettings(
            blockingEnabled: blockingEnabled,
            allowlist: allowlist,
            blockCookieNotices: blockCookieNotices
        )
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
        group.enter()
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: QuietSafariIdentity.russianBundleID) { error in
            outcome.russian = error
            group.leave()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, generation == self.reloadGeneration, self.isBusy else { return }
            self.finishReload(generation: generation, userInitiated: userInitiated, outcome: outcome, timedOut: true)
        }
        group.notify(queue: .main) {
            self.finishReload(generation: generation, userInitiated: userInitiated, outcome: outcome, timedOut: false)
        }
    }

    private func finishReload(generation: Int, userInitiated: Bool, outcome: ReloadOutcome, timedOut: Bool) {
        guard generation == reloadGeneration else { return }
        isBusy = false
        contentBlockerReloadOK = outcome.ads == nil && !timedOut
        privacyReloadOK = outcome.privacy == nil && !timedOut
        russianReloadOK = outcome.russian == nil && !timedOut
        if timedOut {
            if outcome.ads == nil { contentBlockerReloadOK = nil }
            if outcome.privacy == nil { privacyReloadOK = nil }
            if outcome.russian == nil { russianReloadOK = nil }
        }
        refreshExtensionStates()
        guard userInitiated else { return }
        if timedOut && outcome.ads == nil && outcome.privacy == nil && outcome.russian == nil {
            statusMessage = "Safari слишком долго принимает правила. Закройте Safari, удалите старую копию QuietSafari из DerivedData (раздел README «Две копии одного расширения») и нажмите Run ещё раз."
            statusIsError = true
            return
        }
        let failed = [
            outcome.ads == nil ? nil : "QuietSafari Content Blocker",
            outcome.privacy == nil ? nil : "QuietSafari Privacy",
            outcome.russian == nil ? nil : "QuietSafari Russian",
        ].compactMap { $0 }
        if failed.count == 3 {
            statusMessage = "Не удалось применить правила: \(outcome.ads?.localizedDescription ?? ""). Включите расширения в Safari и нажмите кнопку ещё раз."
            statusIsError = true
        } else if !failed.isEmpty {
            statusMessage = "\(failed.joined(separator: ", ")) не принял правила. Включите его в Safari → Настройки → Дополнения и нажмите кнопку ещё раз."
            statusIsError = true
        } else {
            statusMessage = "Правила применены. Обновите уже открытые страницы в Safari."
            statusIsError = false
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
    var russian: Error?
}

enum QuietSafariIdentity {
    static let defaultWebExtensionBundleID = "com.quietsafari.macos.extension"
    static let defaultContentBlockerBundleID = "com.quietsafari.macos.content-blocker"
    static let defaultPrivacyBundleID = "com.quietsafari.macos.privacy"
    static let defaultRussianBundleID = "com.quietsafari.macos.russian"

    static var webExtensionBundleID: String {
        embedded("QuietSafariExtension.appex", fallback: defaultWebExtensionBundleID)
    }

    static var contentBlockerBundleID: String {
        embedded("QuietSafariContentBlocker.appex", fallback: defaultContentBlockerBundleID)
    }

    static var privacyBundleID: String {
        embedded("QuietSafariPrivacy.appex", fallback: defaultPrivacyBundleID)
    }

    static var russianBundleID: String {
        embedded("QuietSafariRussian.appex", fallback: defaultRussianBundleID)
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
