import SwiftUI

/// Settings window. Visible strings are Russian because the owner runs the app himself.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = SettingsStore()
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
        .frame(minWidth: 560, minHeight: 680)
        .onAppear { store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshNow()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color(red: 0.11, green: 0.48, blue: 0.28))
            VStack(alignment: .leading, spacing: 2) {
                Text("QuietSafari")
                    .font(.title2.bold())
                Text("Блокировка рекламы в Safari")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
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
            labeledState("QuietSafari Content Blocker", enabled: store.contentBlockerEnabled)
            labeledState("QuietSafari Privacy", enabled: store.privacyBlockerEnabled)
            labeledState("QuietSafari Russian", enabled: store.russianBlockerEnabled)
            labeledState("QuietSafari", enabled: store.webExtensionEnabled)
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

    private func labeledState(_ title: String, enabled: Bool?) -> some View {
        LabeledContent(title) {
            switch enabled {
            case true:
                Text("включено")
                    .foregroundStyle(.secondary)
            case false:
                Text("выключено")
                    .foregroundStyle(.orange)
            case nil:
                Text("ещё не проверено")
                    .foregroundStyle(.secondary)
            }
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
