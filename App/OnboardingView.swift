import SwiftUI

/// First-launch steps for an ad-hoc build. Safari forgets Allow Unsigned Extensions when it quits.
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
                    Text("Turn on QuietSafari")
                        .font(.title2.weight(.semibold))
                    Text("Four checkboxes in Safari. Without them the lists do nothing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                step("1", "Safari → Settings → Advanced. At the bottom, turn on Show features for web developers.")
                step("2", "In the Develop menu, turn on Allow Unsigned Extensions. macOS will ask for your password. Safari forgets this when you quit it.")
                step("3", "Safari → Settings → Extensions. Turn on QuietSafari, Content Blocker, Privacy, and Russian. Allow QuietSafari on every website.")
                step("4", "If macOS says the app is damaged: System Settings → Privacy & Security → Open Anyway. Or in Terminal: xattr -dr com.apple.quarantine and the path to QuietSafari.app.")
            }

            HStack {
                Button("Open Safari extension settings") {
                    onOpenSafari()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Done") {
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
                .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.14))
                .frame(width: 22, height: 22)
                .background(QuietSafariPalette.logo, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
