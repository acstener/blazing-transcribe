import SwiftUI

extension Color {
    /// Warm off-white main background
    static let btBackground = Color(hex: 0xF9F8F6)
    /// White card background
    static let btCardBackground = Color.white
    /// Warm card hover state
    static let btCardHover = Color(hex: 0xFDFCFB)
    /// Warm beige for selected/active states
    static let btActiveBackground = Color(hex: 0xEFECE8)
    /// Primary text
    static let btText = Color(hex: 0x1A1A1A)
    /// Secondary/muted text
    static let btSecondaryText = Color(hex: 0x6B6B6B)
    /// Border color
    static let btBorder = Color(hex: 0xEAEAEA)

    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
