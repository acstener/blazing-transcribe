import Foundation

public enum OverlayVisualStyle: String, CaseIterable, Codable, Hashable, Sendable {
    case glass
    case black

    public static let defaultsKey = "overlayVisualStyle"

    public static func current(defaults: UserDefaults = .standard) -> OverlayVisualStyle {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let style = OverlayVisualStyle(rawValue: rawValue) else {
            return .black
        }
        return style
    }

    public func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public var title: String {
        switch self {
        case .glass:
            return "Glass"
        case .black:
            return "Black"
        }
    }

    public var subtitle: String {
        switch self {
        case .glass:
            return "Liquid glass on newer Macs, frosted material on older Macs."
        case .black:
            return "Solid black pill with the same overlay behavior and a subtle border."
        }
    }
}
