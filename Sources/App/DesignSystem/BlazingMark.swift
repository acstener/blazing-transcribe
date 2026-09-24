import AppKit
import SwiftUI

/// Resonance: three rising ribbons combine a flame with the rhythm of sound.
/// One vector source keeps the sidebar, home and menu bar silhouettes consistent.
struct BlazingMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 100, rect.height / 128)
        let x = rect.midX - 50 * scale
        let y = rect.midY - 64 * scale
        return Self.outline.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
    }

    private static var outline: Path {
        var p = Path()
        p.move(to: CGPoint(x: 51, y: 2))
        p.addCurve(to: CGPoint(x: 19, y: 51), control1: CGPoint(x: 59, y: 26), control2: CGPoint(x: 33, y: 37))
        p.addCurve(to: CGPoint(x: 15, y: 113), control1: CGPoint(x: -4, y: 72), control2: CGPoint(x: 1, y: 99))
        p.addCurve(to: CGPoint(x: 37, y: 67), control1: CGPoint(x: 7, y: 91), control2: CGPoint(x: 20, y: 79))
        p.addCurve(to: CGPoint(x: 66, y: 30), control1: CGPoint(x: 55, y: 54), control2: CGPoint(x: 73, y: 46))
        p.addCurve(to: CGPoint(x: 51, y: 2), control1: CGPoint(x: 64, y: 18), control2: CGPoint(x: 58, y: 9))
        p.closeSubpath()

        p.move(to: CGPoint(x: 78, y: 37))
        p.addCurve(to: CGPoint(x: 45, y: 77), control1: CGPoint(x: 76, y: 55), control2: CGPoint(x: 57, y: 66))
        p.addCurve(to: CGPoint(x: 40, y: 125), control1: CGPoint(x: 25, y: 94), control2: CGPoint(x: 24, y: 111))
        p.addCurve(to: CGPoint(x: 62, y: 88), control1: CGPoint(x: 34, y: 109), control2: CGPoint(x: 49, y: 99))
        p.addCurve(to: CGPoint(x: 78, y: 37), control1: CGPoint(x: 81, y: 73), control2: CGPoint(x: 94, y: 58))
        p.closeSubpath()

        p.move(to: CGPoint(x: 94, y: 69))
        p.addCurve(to: CGPoint(x: 67, y: 100), control1: CGPoint(x: 91, y: 82), control2: CGPoint(x: 77, y: 89))
        p.addCurve(to: CGPoint(x: 57, y: 126), control1: CGPoint(x: 56, y: 110), control2: CGPoint(x: 51, y: 116))
        p.addCurve(to: CGPoint(x: 94, y: 69), control1: CGPoint(x: 82, y: 113), control2: CGPoint(x: 106, y: 94))
        p.closeSubpath()
        return p
    }

    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 16, height: 20)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(BlazingMark().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Blazing Transcribe"
        return image
    }
}
