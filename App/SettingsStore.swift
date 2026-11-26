import AppKit
import Foundation
import SafariServices
import ServiceManagement

/// Settings the owner sees. The app is the source of truth for the switch and the allowlist.
/// The web extension is the source of truth for the counter it can actually observe.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    @Published var blockingEnabled: Bool
    @Published var allowlist: [String]
    @Published var blockCookieNotices: Bool
    @Published var hideDockIcon: Bool
    @Published var launchAtLogin: Bool
    @Published var currentHost = ""
    @Published var blockedCount: Int
    @Published var appGroupAvailable: Bool
    @Published var appGroupID: String
    @Published var contentBlockerEnabled: Bool?
    @Published var privacyBlockerEnabled: Bool?
    @Published var russianBlockerEnabled: Bool?
    @Published var contentBlockerProblem = ""
    @Published var privacyProblem = ""
    @Published var russianProblem = ""
    @Published var contentBlockerUpdating = false
    @Published var privacyUpdating = false
    @Published var russianUpdating = false
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
        hideDockIcon = settings.hideDockIcon
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
        applyDockPolicy()
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
        let host = QuietSafariShared.readCurrentHost()
        if host != currentHost {
            currentHost = host
        }
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

    func setHideDockIcon(_ hidden: Bool) {
        hideDockIcon = hidden
        applyDockPolicy()
        let settings = QuietSafariSettings(
            blockingEnabled: blockingEnabled,
            allowlist: allowlist,
            blockCookieNotices: blockCookieNotices,
            hideDockIcon: hideDockIcon
        )
        if !QuietSafariShared.writeSettings(settings) {
            statusMessage = "Не удалось сохранить настройку значка."
            statusIsError = true
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            statusMessage = enabled ? "QuietSafari откроется при входе в систему." : "Автозапуск выключен."
            statusIsError = false
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            statusMessage = "Автозапуск: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    private func decide(api: Bool?, servedName: String, reloadOK: Bool?, sawAPITrue: inout Bool) -> Bool? {
        if reloadOK == false {
            return false
        }
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
            blockCookieNotices: blockCookieNotices,
            hideDockIcon: hideDockIcon
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
        contentBlockerProblem = ""
        privacyProblem = ""
        russianProblem = ""
        contentBlockerUpdating = true
        privacyUpdating = true
        russianUpdating = true
        let outcome = ReloadOutcome()
        let steps = [
            ReloadStep(keyPath: \.ads, identifier: QuietSafariIdentity.contentBlockerBundleID) {
                self.contentBlockerUpdating = false
            },
            ReloadStep(keyPath: \.privacy, identifier: QuietSafariIdentity.privacyBundleID) {
                self.privacyUpdating = false
            },
            ReloadStep(keyPath: \.russian, identifier: QuietSafariIdentity.russianBundleID) {
                self.russianUpdating = false
            },
        ]
        // One reload at a time. Safari returns SFErrorDomain error 3 (loading interrupted)
        // when several content blockers compile at once, even though the previous rules stay active.
        reloadStep(steps, index: 0, generation: generation, userInitiated: userInitiated, outcome: outcome)
    }

    private func reloadStep(
        _ steps: [ReloadStep],
        index: Int,
        generation: Int,
        userInitiated: Bool,
        outcome: ReloadOutcome
    ) {
        guard generation == reloadGeneration else { return }
        guard index < steps.count else {
            finishReload(generation: generation, userInitiated: userInitiated, outcome: outcome)
            return
        }
        let step = steps[index]
        reloadOne(identifier: step.identifier, attempt: 0) { [weak self] error in
            guard let self, generation == self.reloadGeneration else { return }
            outcome[keyPath: step.keyPath] = error
            step.markDone()
            self.reloadStep(steps, index: index + 1, generation: generation, userInitiated: userInitiated, outcome: outcome)
        }
    }

    /// Three attempts, then the error (if any) is reported. Interrupted loads wait and try again.
    private func reloadOne(identifier: String, attempt: Int, completion: @escaping (Error?) -> Void) {
        let gate = ReloadGate()
        let timeout = DispatchWorkItem { [weak self] in
            guard !gate.done else { return }
            gate.done = true
            guard let self else { return }
            if attempt < 2 {
                self.reloadOne(identifier: identifier, attempt: attempt + 1, completion: completion)
            } else {
                completion(Self.interruptedError)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier) { [weak self] error in
            DispatchQueue.main.async {
                guard !gate.done else { return }
                gate.done = true
                timeout.cancel()
                guard let self else { return }
                if let error, Self.isLoadingInterrupted(error), attempt < 2 {
                    let delay = 0.5 * pow(2.0, Double(attempt))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.reloadOne(identifier: identifier, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(error)
            }
        }
    }

    private static func isLoadingInterrupted(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "SFErrorDomain" && nsError.code == 3
    }

    /// Same code Safari uses when a reload is cancelled because another one is in flight.
    private static let interruptedError = NSError(domain: "SFErrorDomain", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "The operation couldn’t be completed. (SFErrorDomain error 3.)",
    ])

    private func finishReload(generation: Int, userInitiated: Bool, outcome: ReloadOutcome) {
        guard generation == reloadGeneration else { return }
        isBusy = false
        contentBlockerUpdating = false
        privacyUpdating = false
        russianUpdating = false
        let ads = Self.classify(outcome.ads)
        let privacy = Self.classify(outcome.privacy)
        let russian = Self.classify(outcome.russian)
        contentBlockerProblem = ads.problem
        privacyProblem = privacy.problem
        russianProblem = russian.problem
        contentBlockerReloadOK = ads.reloadOK
        privacyReloadOK = privacy.reloadOK
        russianReloadOK = russian.reloadOK
        refreshExtensionStates()
        let lines = [
            ads.problem.isEmpty ? nil : "QuietSafari Content Blocker: \(ads.problem)",
            privacy.problem.isEmpty ? nil : "QuietSafari Privacy: \(privacy.problem)",
            russian.problem.isEmpty ? nil : "QuietSafari Russian: \(russian.problem)",
        ].compactMap { $0 }
        if !lines.isEmpty {
            statusMessage = lines.joined(separator: "\n")
            statusIsError = true
            return
        }
        if userInitiated {
            if ads.interrupted || privacy.interrupted || russian.interrupted {
                statusMessage = "Safari прервал обновление. Уже загруженные правила остаются, блокировка не сбрасывается."
                statusIsError = false
            } else {
                statusMessage = "Правила применены. Обновите уже открытые страницы в Safari."
                statusIsError = false
            }
        }
    }

    /// Interrupted reloads are not rule rejections. A missing extension is «выключено», not «ошибка».
    private static func classify(_ error: Error?) -> (problem: String, reloadOK: Bool?, interrupted: Bool) {
        guard let error else { return ("", true, false) }
        let nsError = error as NSError
        if nsError.domain == "SFErrorDomain" && nsError.code == 3 {
            return ("", nil, true)
        }
        if nsError.domain == "SFErrorDomain" && nsError.code == 1 {
            return ("", false, false)
        }
        return (nsError.localizedDescription, false, false)
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

private struct ReloadStep {
    let keyPath: ReferenceWritableKeyPath<ReloadOutcome, Error?>
    let identifier: String
    let markDone: () -> Void
}

private final class ReloadGate {
    var done = false
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
