import AppKit
import Combine
import SwiftUI

/// Menu-bar control. The leaf is a template image so macOS draws it for light and dark menus.
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let store: SettingsStore
    private var iconObserver: AnyCancellable?

    init(store: SettingsStore) {
        self.store = store
        super.init()
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        applyStatusIcon(blockingEnabled: store.blockingEnabled)
        iconObserver = store.$blockingEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.applyStatusIcon(blockingEnabled: enabled)
            }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 560)
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

    private func applyStatusIcon(blockingEnabled: Bool) {
        let name = blockingEnabled ? "MenuBarIcon" : "MenuBarIconOutline"
        let image = NSImage(named: name) ?? NSImage(systemSymbolName: "leaf", accessibilityDescription: "QuietSafari")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
    }
}

private struct MenuBarView: View {
    @ObservedObject var store: SettingsStore
    @State private var draft = ""

    var body: some View {
        ScrollView {
            menuBody
        }
        .frame(width: 300)
    }

    private var menuBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.safariResetNotice {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Safari reset the permission. Turn it on again.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Safari settings") {
                        store.openSafariExtensionSettings()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QuietSafariPalette.sage.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 8) {
                Image("QuietSafariMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("QuietSafari")
                Text("QuietSafari")
                    .font(.headline)
                Spacer()
            }
            Toggle("Blocking", isOn: Binding(
                get: { store.blockingEnabled },
                set: { store.setBlockingEnabled($0) }
            ))
            .toggleStyle(.switch)
            siteRow
            LabeledContent("Blocked") {
                Text("\(store.blockedCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                statusLine("Content Blocker", on: store.contentBlockerEnabled, problem: store.contentBlockerProblem, updating: store.contentBlockerUpdating)
                statusLine("Privacy", on: store.privacyBlockerEnabled, problem: store.privacyProblem, updating: store.privacyUpdating)
                statusLine("Russian", on: store.russianBlockerEnabled, problem: store.russianProblem, updating: store.russianUpdating)
                statusLine("Web extension", on: store.webExtensionEnabled, problem: "", updating: false)
            }
            if let hint = offHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Update filters") { store.reapplyRules() }
                .disabled(store.isBusy)
            Button("Open settings") { store.showMainWindow() }
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            Toggle("Hide Dock icon", isOn: Binding(
                get: { store.hideDockIcon },
                set: { store.setHideDockIcon($0) }
            ))
            Button("Quit QuietSafari") { store.quit() }
                .keyboardShortcut("q")
        }
        .padding(14)
        .tint(QuietSafariPalette.sage)
    }

    private var siteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.currentHost.isEmpty {
                TextField("example.com", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Don’t block this site") {
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
                Text(store.allowlist.contains(store.currentHost) ? "Site is allowed" : "Blocking on this site")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var offHint: String? {
        if store.contentBlockerUpdating || store.privacyUpdating || store.russianUpdating {
            return nil
        }
        let problems = [store.contentBlockerProblem, store.privacyProblem, store.russianProblem].filter { !$0.isEmpty }
        if !problems.isEmpty {
            return problems.joined(separator: " ")
        }
        if store.contentBlockerEnabled == false || store.privacyBlockerEnabled == false || store.russianBlockerEnabled == false || store.webExtensionEnabled == false {
            return "One extension is off. Safari → Settings → Extensions."
        }
        return nil
    }

    private func statusLine(_ title: String, on: Bool?, problem: String, updating: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(on: on, problem: problem, updating: updating))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
            Spacer()
            Text(label(on: on, problem: problem, updating: updating))
                .font(.caption)
                .foregroundStyle(problem.isEmpty || updating ? Color.secondary : Color.orange)
        }
    }

    private func color(on: Bool?, problem: String, updating: Bool) -> Color {
        if updating {
            return QuietSafariPalette.sage.opacity(0.85)
        }
        if !problem.isEmpty || on == false {
            return .orange
        }
        if on == true {
            return QuietSafariPalette.sage
        }
        return .secondary
    }

    private func label(on: Bool?, problem: String, updating: Bool) -> String {
        if updating {
            return "updating…"
        }
        if !problem.isEmpty {
            return "error"
        }
        switch on {
        case true: return "on"
        case false: return "off"
        case nil: return "…"
        }
    }
}
