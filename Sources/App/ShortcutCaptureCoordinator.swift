import Foundation

extension Notification.Name {
    static let shortcutCaptureStateDidChange = Notification.Name("shortcutCaptureStateDidChange")
}

enum ShortcutCaptureNotificationKey {
    static let activeSessionID = "activeSessionID"
    static let isCapturing = "isCapturing"
}

@MainActor
final class ShortcutCaptureCoordinator {
    static let shared = ShortcutCaptureCoordinator()

    private(set) var activeSessionID: UUID?

    var isCapturing: Bool {
        activeSessionID != nil
    }

    private init() {}

    func begin(_ sessionID: UUID) {
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        postChange()
    }

    func end(_ sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        postChange()
    }

    private func postChange() {
        var userInfo: [String: Any] = [
            ShortcutCaptureNotificationKey.isCapturing: isCapturing,
        ]

        if let activeSessionID {
            userInfo[ShortcutCaptureNotificationKey.activeSessionID] = activeSessionID.uuidString
        }

        NotificationCenter.default.post(
            name: .shortcutCaptureStateDidChange,
            object: nil,
            userInfo: userInfo
        )
    }
}
