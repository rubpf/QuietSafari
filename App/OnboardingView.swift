import SwiftUI

/// First-launch steps for an ad-hoc build. Safari forgets "Allow Unsigned Extensions" when it quits.
struct OnboardingView: View {
    var onOpenSafari: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image("QuietSafariMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("QuietSafari")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Включить QuietSafari")
                        .font(.title2.weight(.semibold))
                    Text("Четыре галочки в Safari. Без них списки молчат.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                step("1", "Safari → Настройки → Дополнительно. Внизу включите «Показывать функции для веб-разработчиков».")
                step("2", "В меню «Разработка» включите «Разрешить неподписанные расширения». macOS спросит пароль. Safari забывает этот пункт, когда его полностью закрывают.")
                step("3", "Safari → Настройки → Дополнения. Включите QuietSafari, Content Blocker, Privacy и Russian. У QuietSafari разрешите все сайты.")
                step("4", "Если macOS пишет, что приложение повреждено: Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть». Либо в Терминале: xattr -dr com.apple.quarantine и путь к QuietSafari.app.")
            }

            HStack {
                Button("Открыть настройки дополнений Safari") {
                    onOpenSafari()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Готово") {
                    onDone()
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .tint(QuietSafariPalette.sage)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(QuietSafariPalette.sage, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
