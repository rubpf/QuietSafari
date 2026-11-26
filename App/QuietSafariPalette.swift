import SwiftUI

/// One accent for the menu bar and the settings window.
/// Dark mode uses the logo background sampled from the chosen mark (#C8D0B5).
/// Light mode uses a deeper shade of that sage so toggles stay readable on white.
enum QuietSafariPalette {
    static let sage = Color("AccentColor")
    static let logo = Color(red: 200.0 / 255.0, green: 208.0 / 255.0, blue: 181.0 / 255.0)
}
