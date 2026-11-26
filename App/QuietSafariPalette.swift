import SwiftUI

/// One accent for the menu bar and the settings window.
/// Dark mode uses the logo background (#A8C49A). Light mode uses a deeper shade of the same sage so toggles stay readable on white.
enum QuietSafariPalette {
    static let sage = Color("AccentColor")
    static let logo = Color(red: 168.0 / 255.0, green: 196.0 / 255.0, blue: 154.0 / 255.0)
}
