import SwiftUI

enum RecipeTheme {
    static let paper = Color(light: 0xF4F1EA, dark: 0x191714)
    static let surface = Color(light: 0xFBF9F4, dark: 0x24211D)
    static let ink = Color(light: 0x2A2420, dark: 0xF2EDE5)
    static let secondaryInk = Color(light: 0x766E66, dark: 0xB9B0A5)
    static let grid = Color(light: 0xD8CCBC, dark: 0x4A433B)
    static let stage = Color(light: 0xEEE5DD, dark: 0x332D28)
    static let stageAlternate = Color(light: 0xE7DDD1, dark: 0x3A322C)
    static let focus = Color(light: 0xC66E71, dark: 0xE99A9D)
    static let warning = Color(light: 0xA45A24, dark: 0xF0A968)
    static let success = Color(light: 0x57735B, dark: 0x8FC49A)
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    func editorialSurface() -> some View {
        foregroundStyle(RecipeTheme.ink)
            .background(RecipeTheme.paper.ignoresSafeArea())
            .tint(RecipeTheme.focus)
    }
}

