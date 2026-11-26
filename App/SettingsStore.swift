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
    @Published var webExtensionEnabled: Bool?
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var isBusy = false

    private let server = TestPageServer()
    private var timer: Timer?
    private var started = false
    private var pollTick = 0
    private var reloadGeneration = 0

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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "Версия \(version). Пока используется короткий проверочный список. EasyList и EasyPrivacy подключаются на следующем этапе."
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
        persistAndReload(userInitiated: true)
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
        let blockerID = QuietSafariIdentity.contentBlockerBundleID
        let extensionID = QuietSafariIdentity.webExtensionBundleID
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: blockerID) { state, _ in
            DispatchQueue.main.async {
                if let state {
                    self.contentBlockerEnabled = state.isEnabled
                }
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

    private func persistAndReload(userInitiated: Bool, revert: (() -> Void)? = nil) {
        appGroupAvailable = QuietSafariShared.containerURL != nil
        appGroupID = QuietSafariShared.appGroupID
        let settings = QuietSafariSettings(blockingEnabled: blockingEnabled, allowlist: allowlist)

        guard QuietSafariShared.containerURL != nil else {
            revert?()
            if userInitiated || statusMessage.isEmpty {
                statusMessage = "Общая папка между приложением и расширениями недоступна. Скрытие по встроенному списку всё равно работает. Чтобы заработали переключатель и белый список, выберите одну и ту же команду (Team) у всех трёх целей и нажмите Run ещё раз."
                statusIsError = true
            }
            return
        }

        guard let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json"),
              let baseJSON = try? Data(contentsOf: bundledURL) else {
            revert?()
            statusMessage = RuleCompiler.CompileError.unreadable.localizedDescription
            statusIsError = true
            return
        }

        let compiled: Data
        do {
            compiled = try RuleCompiler.compile(baseJSON: baseJSON, settings: settings)
        } catch {
            revert?()
            statusMessage = error.localizedDescription
            statusIsError = true
            return
        }

        guard QuietSafariShared.writeSettings(settings), QuietSafariShared.writeRules(compiled) else {
            revert?()
            statusMessage = "Не удалось записать правила в общую папку."
            statusIsError = true
            return
        }

        isBusy = true
        reloadGeneration += 1
        let generation = reloadGeneration
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: QuietSafariIdentity.contentBlockerBundleID) { error in
            DispatchQueue.main.async {
                guard generation == self.reloadGeneration else {
                    return
                }
                self.isBusy = false
                self.refreshExtensionStates()
                guard userInitiated else {
                    return
                }
                if let error {
                    self.statusMessage = "Не удалось применить правила: \(error.localizedDescription). Если расширение ещё не включено в Safari, включите его и нажмите кнопку ещё раз."
                    self.statusIsError = true
                } else {
                    self.statusMessage = "Правила применены. Обновите уже открытые страницы в Safari."
                    self.statusIsError = false
                }
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

enum QuietSafariIdentity {
    static let defaultWebExtensionBundleID = "com.quietsafari.macos.extension"
    static let defaultContentBlockerBundleID = "com.quietsafari.macos.content-blocker"

    static var webExtensionBundleID: String {
        resolved("QuietSafariWebExtensionBundleID", fallback: defaultWebExtensionBundleID)
    }

    static var contentBlockerBundleID: String {
        resolved("QuietSafariContentBlockerBundleID", fallback: defaultContentBlockerBundleID)
    }

    private static func resolved(_ key: String, fallback: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty || value.contains("$") {
            return fallback
        }
        return value
    }
}
