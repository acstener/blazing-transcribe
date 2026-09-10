import AppKit
import SwiftUI

extension Color {
    /// Warm off-white main background / warm charcoal in dark
    static let btBackground = adaptive(light: 0xF9F8F6, dark: 0x1C1B1A)
    /// White card background / raised dark card
    static let btCardBackground = adaptive(light: 0xFFFFFF, dark: 0x2A2927)
    /// Warm card hover state
    static let btCardHover = adaptive(light: 0xFDFCFB, dark: 0x32312E)
    /// Warm beige for selected/active states
    static let btActiveBackground = adaptive(light: 0xEFECE8, dark: 0x3A3835)
    /// Primary text
    static let btText = adaptive(light: 0x1A1A1A, dark: 0xF2F0ED)
    /// Secondary/muted text
    static let btSecondaryText = adaptive(light: 0x6B6B6B, dark: 0xA8A6A3)
    /// Border color
    static let btBorder = adaptive(light: 0xEAEAEA, dark: 0x3F3D3A)
    /// Inverted fill for primary buttons (dark on light, light on dark)
    static let btPrimaryFill = adaptive(light: 0x1A1A1A, dark: 0xF2F0ED)
    /// Text/icon on `btPrimaryFill`
    static let btOnPrimary = adaptive(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// Card drop shadow that stays visible in both appearances
    static let btCardShadow = adaptive(
        light: 0x000000,
        dark: 0x000000,
        lightOpacity: 0.03,
        darkOpacity: 0.45
    )

    private static func adaptive(
        light: UInt,
        dark: UInt,
        lightOpacity: Double = 1.0,
        darkOpacity: Double = 1.0
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let opacity = isDark ? darkOpacity : lightOpacity
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: opacity
            )
        })
    }

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
