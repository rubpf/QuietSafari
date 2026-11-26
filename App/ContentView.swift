import SwiftUI

/// Settings window. Visible strings are Russian because the owner runs the app himself.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: SettingsStore
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
        .onAppear { store.start() }
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
                Text("Блокировка рекламы в Safari")
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
            Toggle("Блокировка включена", isOn: Binding(
                get: { store.blockingEnabled },
                set: { store.setBlockingEnabled($0) }
            ))
            .disabled(store.isBusy)
        } header: {
            Text("Блокировка")
        } footer: {
            Text("Выключение очищает правила Safari. Уже открытую страницу нужно обновить.")
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
            Text("Отмечено на страницах")
        } footer: {
            Text("Считает то, что увидела программа на странице: рекламные блоки и пропущенную рекламу YouTube. Сколько адресов Safari оборвал сам, он не сообщает — так устроен блокировщик контента.")
        }
    }

    private var allowlistSection: some View {
        Section {
            HStack {
                TextField("example.com", text: $draft)
                    .onSubmit(addDraft)
                Button("Добавить", action: addDraft)
                    .disabled(store.isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if store.allowlist.isEmpty {
                Text("Пока пусто — реклама блокируется на всех сайтах.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.allowlist, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Удалить") {
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
            Text("Не блокировать на этих сайтах")
        } footer: {
            Text("Пишите адрес как example.com. www в начале можно не указывать: исключение покроет и сайт, и его поддомены.")
        }
    }

    private var filtersSection: some View {
        Section {
            Button("Обновить фильтры") {
                store.reapplyRules()
            }
            .disabled(store.isBusy)
            Toggle("Скрывать окна про cookie", isOn: Binding(
                get: { store.blockCookieNotices },
                set: { store.setBlockCookieNotices($0) }
            ))
            .disabled(store.isBusy)
            Text(store.versionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Фильтры")
        } footer: {
            Text("Кнопка скачивает EasyList, EasyPrivacy и RU AdList и переводит их в правила Safari. Окна про cookie выключены, пока вы сами не включите переключатель.")
        }
    }

    private var testSection: some View {
        Section {
            Button("Открыть проверочную страницу") {
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
            Text("Проверка")
        } footer: {
            Text("Страница открывается в Safari на этом компьютере. Красного блока «РЕКЛАМА» быть не должно. Обычный текст под ним должен остаться.")
        }
    }

    private var stateSection: some View {
        Section {
            labeledState("QuietSafari Content Blocker", enabled: store.contentBlockerEnabled, problem: store.contentBlockerProblem, updating: store.contentBlockerUpdating)
            labeledState("QuietSafari Privacy", enabled: store.privacyBlockerEnabled, problem: store.privacyProblem, updating: store.privacyUpdating)
            labeledState("QuietSafari Russian", enabled: store.russianBlockerEnabled, problem: store.russianProblem, updating: store.russianUpdating)
            labeledState("QuietSafari", enabled: store.webExtensionEnabled, problem: "", updating: false)
            LabeledContent("Общая папка") {
                Text(store.appGroupAvailable ? "доступна" : "недоступна")
                    .foregroundStyle(store.appGroupAvailable ? Color.secondary : Color.orange)
            }
            Text(store.appGroupID)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        } header: {
            Text("Состояние")
        }
    }

    private var helpSection: some View {
        Section {
            Text(helpText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Как включить в Safari")
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
            return "обновляется…"
        }
        if !problem.isEmpty {
            return "ошибка"
        }
        switch enabled {
        case true: return "включено"
        case false: return "выключено"
        case nil: return "ещё не проверено"
        }
    }

    private func elementWord(_ count: Int) -> String {
        let value = abs(count) % 100
        let last = value % 10
        if value > 10 && value < 20 {
            return "элементов"
        }
        if last == 1 {
            return "элемент"
        }
        if last >= 2 && last <= 4 {
            return "элемента"
        }
        return "элементов"
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
        1. Safari → Настройки → Дополнительно → включите «Показывать функции для веб-разработчиков».
        2. Меню «Разработка» → «Разрешить неподписанные расширения». Safari забывает этот пункт, когда его полностью закрывают.
        3. Safari → Настройки → Дополнения. Включите четыре пункта: QuietSafari, QuietSafari Content Blocker, QuietSafari Privacy и QuietSafari Russian.
        4. У QuietSafari разрешите доступ ко всем сайтам. Content Blocker — EasyList, Privacy — EasyPrivacy, Russian — RU AdList и реклама Яндекса, QuietSafari — YouTube, скрипты списков и счётчик.
        """
    }
}
