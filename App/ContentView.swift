import SwiftUI

/// Settings window. Visible strings are Russian because the owner runs the app himself.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: SettingsStore
    @AppStorage("quietSafari.didFinishOnboarding") private var didFinishOnboarding = false
    @State private var showOnboarding = false
    @State private var draft = ""
    @State private var draftMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Form {
                blockingSection
                counterSection
                allowlistSection
                filtersSection
                testSection
                stateSection
                helpSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 580, minHeight: 720)
        .tint(QuietSafariPalette.sage)
        .onAppear {
            store.start()
            if !didFinishOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: { didFinishOnboarding = true }) {
            OnboardingView(
                onOpenSafari: { store.openSafariExtensionSettings() },
                onDone: { showOnboarding = false }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshNow()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image("QuietSafariMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityLabel("QuietSafari")
            VStack(alignment: .leading, spacing: 3) {
                Text("QuietSafari")
                    .font(.title2.weight(.semibold))
                Text("Ad blocking for Safari")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var blockingSection: some View {
        Section {
            Toggle("Blocking on", isOn: Binding(
                get: { store.blockingEnabled },
                set: { store.setBlockingEnabled($0) }
            ))
            .disabled(store.isBusy)
        } header: {
            Text("Blocking")
        } footer: {
            Text("Turning this off clears Safari’s rules. Reload pages that are already open.")
        }
    }

    private var counterSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("\(store.blockedCount)")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(elementWord(store.blockedCount))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Seen on pages")
        } footer: {
            Text("Counts ad slots and skipped YouTube ads the extension can see. Safari does not report how many network requests it blocked.")
        }
    }

    private var allowlistSection: some View {
        Section {
            HStack {
                TextField("example.com", text: $draft)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(store.isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if store.allowlist.isEmpty {
                Text("Empty, so ads are blocked on every site.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.allowlist, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Remove") {
                            store.removeSite(site)
                        }
                        .disabled(store.isBusy)
                    }
                }
            }
            if !draftMessage.isEmpty {
                Text(draftMessage)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Don’t block these sites")
        } footer: {
            Text("Use example.com. A leading www is optional: the exception covers the site and its subdomains.")
        }
    }

    private var filtersSection: some View {
        Section {
            Button("Update filters") {
                store.reapplyRules()
            }
            .disabled(store.isBusy)
            Toggle("Hide cookie notices", isOn: Binding(
                get: { store.blockCookieNotices },
                set: { store.setBlockCookieNotices($0) }
            ))
            .disabled(store.isBusy)
            Text(store.versionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Filters")
        } footer: {
            Text("Downloads EasyList, EasyPrivacy, and RU AdList and converts them into Safari rules. Cookie notices stay visible until you turn the switch on.")
        }
    }

    private var testSection: some View {
        Section {
            Button("Open test page") {
                store.openTestPage()
            }
            .disabled(store.isBusy)
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .foregroundStyle(store.statusIsError ? Color.orange : Color.secondary)
            }
        } header: {
            Text("Check")
        } footer: {
            Text("Opens a page in Safari on this Mac. The red AD blocks should be gone. The green paragraph under them should stay.")
        }
    }

    private var stateSection: some View {
        Section {
            labeledState("QuietSafari Content Blocker", enabled: store.contentBlockerEnabled, problem: store.contentBlockerProblem, updating: store.contentBlockerUpdating)
            labeledState("QuietSafari Privacy", enabled: store.privacyBlockerEnabled, problem: store.privacyProblem, updating: store.privacyUpdating)
            labeledState("QuietSafari Russian", enabled: store.russianBlockerEnabled, problem: store.russianProblem, updating: store.russianUpdating)
            labeledState("QuietSafari", enabled: store.webExtensionEnabled, problem: "", updating: false)
            LabeledContent("Shared folder") {
                Text(store.appGroupAvailable ? "available" : "unavailable")
                    .foregroundStyle(store.appGroupAvailable ? Color.secondary : Color.orange)
            }
            Text(store.appGroupID)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        } header: {
            Text("Status")
        }
    }

    private var helpSection: some View {
        Section {
            if store.safariResetNotice {
                Text("Safari reset the permission. Turn it on again.")
                    .foregroundStyle(.secondary)
                Button("Open Safari settings") {
                    store.openSafariExtensionSettings()
                }
            }
            Button("Show setup steps") {
                showOnboarding = true
            }
            Text(helpText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Turn on in Safari")
        }
    }

    private func labeledState(_ title: String, enabled: Bool?, problem: String, updating: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor(enabled, problem: problem, updating: updating))
                        .frame(width: 8, height: 8)
                    Text(statusWord(enabled, problem: problem, updating: updating))
                        .foregroundStyle(problem.isEmpty || updating ? Color.secondary : Color.orange)
                }
            }
            if !problem.isEmpty && !updating {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dotColor(_ enabled: Bool?, problem: String, updating: Bool) -> Color {
        if updating {
            return QuietSafariPalette.sage.opacity(0.85)
        }
        if !problem.isEmpty || enabled == false {
            return .orange
        }
        if enabled == true {
            return QuietSafariPalette.sage
        }
        return Color.secondary.opacity(0.45)
    }

    private func statusWord(_ enabled: Bool?, problem: String, updating: Bool) -> String {
        if updating {
            return "updating…"
        }
        if !problem.isEmpty {
            return "error"
        }
        switch enabled {
        case true: return "on"
        case false: return "off"
        case nil: return "not checked yet"
        }
    }

    private func elementWord(_ count: Int) -> String {
        count == 1 ? "item" : "items"
    }

    private func addDraft() {
        if let message = store.addSite(draft) {
            draftMessage = message
            return
        }
        draft = ""
        draftMessage = ""
    }

    private var helpText: String {
        """
        1. Safari → Settings → Advanced → turn on Show features for web developers.
        2. Develop menu → Allow Unsigned Extensions. Safari forgets this when you quit it.
        3. Safari → Settings → Extensions. Turn on QuietSafari, QuietSafari Content Blocker, QuietSafari Privacy, and QuietSafari Russian.
        4. Allow QuietSafari on every website. Content Blocker is EasyList, Privacy is EasyPrivacy, Russian is RU AdList and Yandex ads, QuietSafari is YouTube, list scripts, and the counter.
        """
    }
}
