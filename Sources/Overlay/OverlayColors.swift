import SwiftUI
import AppKit

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

    /// Blazing's live-moment signal colour (matches `btEmber` in the app).
    static let overlayEmber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0x6B / 255, blue: 0x2C / 255, alpha: 1)
            : NSColor(srgbRed: 0xE8 / 255, green: 0x59 / 255, blue: 0x0C / 255, alpha: 1)
    })
    /// Amber warning, distinct from Ember.
    static let overlayWarning = Color(overlayHex: 0xF2B400)

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
