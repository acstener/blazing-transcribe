import SwiftUI

// MARK: - Sage Green Palette

extension Color {
    /// Frosted sage glass background
    static let overlayBackground = Color(overlayHex: 0xE8EDE6, opacity: 0.8)
    /// Subtle sage border
    static let overlayBorder = Color(overlayHex: 0xD1DDD0)
    /// Waveform bar color
    static let overlayBarColor = Color(overlayHex: 0x4A5D4C)
    /// Deep sage text
    static let overlayText = Color(overlayHex: 0x2A3B2C)
    /// Dimmed partial tail text
    static let overlaySecondaryText = Color(overlayHex: 0x2A3B2C, opacity: 0.6)

    init(overlayHex hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
