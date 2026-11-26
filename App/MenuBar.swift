import AppKit
import SwiftUI

/// Menu-bar control. The leaf is a template image so macOS draws it for light and dark menus.
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        super.init()
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "leaf", accessibilityDescription: "QuietSafari")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 420)
        popover.contentViewController = NSHostingController(rootView: MenuBarView(store: store))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else {
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarView: View {
    @ObservedObject var store: SettingsStore
    @State private var draft = ""

    private var accent: Color { Color(red: 0.11, green: 0.48, blue: 0.28) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(accent)
                Text("QuietSafari")
                    .font(.headline)
                Spacer()
            }
            Toggle("Блокировка", isOn: Binding(
                get: { store.blockingEnabled },
                set: { store.setBlockingEnabled($0) }
            ))
            .toggleStyle(.switch)
            siteRow
            LabeledContent("Отмечено") {
                Text("\(store.blockedCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                statusLine("Content Blocker", on: store.contentBlockerEnabled, problem: store.contentBlockerProblem)
                statusLine("Privacy", on: store.privacyBlockerEnabled, problem: store.privacyProblem)
                statusLine("Russian", on: store.russianBlockerEnabled, problem: store.russianProblem)
                statusLine("Веб-расширение", on: store.webExtensionEnabled, problem: "")
            }
            if let hint = offHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Обновить фильтры") { store.reapplyRules() }
                .disabled(store.isBusy)
            Button("Открыть настройки") { store.showMainWindow() }
            Toggle("Запускать при входе", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            Toggle("Скрыть значок в Dock", isOn: Binding(
                get: { store.hideDockIcon },
                set: { store.setHideDockIcon($0) }
            ))
            Button("Завершить QuietSafari") { store.quit() }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }

    private var siteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.currentHost.isEmpty {
                TextField("example.com", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Не блокировать этот адрес") {
                    _ = store.addSite(draft)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Toggle(store.currentHost, isOn: Binding(
                    get: { !store.allowlist.contains(store.currentHost) },
                    set: { enabled in
                        if enabled {
                            store.removeSite(store.currentHost)
                        } else if !store.allowlist.contains(store.currentHost) {
                            _ = store.addSite(store.currentHost)
                        }
                    }
                ))
                Text(store.allowlist.contains(store.currentHost) ? "Сайт в белом списке" : "Блокировка на этом сайте")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var offHint: String? {
        let problems = [store.contentBlockerProblem, store.privacyProblem, store.russianProblem].filter { !$0.isEmpty }
        if !problems.isEmpty {
            return problems.joined(separator: " ")
        }
        if store.contentBlockerEnabled == false || store.privacyBlockerEnabled == false || store.russianBlockerEnabled == false || store.webExtensionEnabled == false {
            return "Одно из расширений выключено. Safari → Настройки → Дополнения."
        }
        return nil
    }

    private func statusLine(_ title: String, on: Bool?, problem: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(on: on, problem: problem))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
            Spacer()
            Text(label(on: on, problem: problem))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func color(on: Bool?, problem: String) -> Color {
        if !problem.isEmpty || on == false {
            return .orange
        }
        if on == true {
            return accent
        }
        return .secondary
    }

    private func label(on: Bool?, problem: String) -> String {
        if !problem.isEmpty {
            return "ошибка"
        }
        switch on {
        case true: return "вкл"
        case false: return "выкл"
        case nil: return "…"
        }
    }
}
