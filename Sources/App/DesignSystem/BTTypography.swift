import SwiftUI

extension Font {
    /// Display/hero: SF Pro Rounded Bold 32pt
    static let btDisplay = Font.system(size: 32, weight: .bold, design: .rounded)
    /// Section title: 24pt semibold
    static let btTitle = Font.system(size: 24, weight: .semibold)
    /// Body: 15pt regular
    static let btBody = Font.system(size: 15)
    /// Caption: 12pt regular
    static let btCaption = Font.system(size: 12)
    /// Label: 11pt medium
    static let btLabel = Font.system(size: 11, weight: .medium)
    /// Mono: 13pt monospaced
    static let btMono = Font.system(size: 13, design: .monospaced)
}
