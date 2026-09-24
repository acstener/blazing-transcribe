import SwiftUI
import AppKit

extension Color {
    static let btBackground = adaptive(light: 0xF7F7F5, dark: 0x191A1C)
    static let btCardBackground = adaptive(light: 0xFFFFFF, dark: 0x242527)
    static let btCardHover = adaptive(light: 0xF3F3F1, dark: 0x2B2C2F)
    static let btActiveBackground = adaptive(light: 0xEAEAE7, dark: 0x333438)
    static let btText = adaptive(light: 0x202321, dark: 0xF0F1EE)
    static let btSecondaryText = adaptive(light: 0x686D69, dark: 0xA7ACA8)
    static let btBorder = adaptive(light: 0xE3E5E1, dark: 0x383B38)

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
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
