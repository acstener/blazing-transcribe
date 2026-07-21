import AppKit

/// Fetches remote announcements from the website and shows them to the user.
///
/// JSON format at /announcements.json:
/// ```
/// {
///   "announcements": [
///     {
///       "id": "2026-03-06-manual-mode",
///       "title": "Manual mode is here!",
///       "body": "Hold fn to push-to-talk...",
///       "buttonLabel": "Learn more",          // optional
///       "buttonURL": "https://...",            // optional
///       "minVersion": "1.0.3",                // optional — only show to users on this version or above
///       "maxVersion": "1.0.5"                 // optional — stop showing after this version
///     }
///   ]
/// }
/// ```
final class AnnouncementService {

    static let shared = AnnouncementService()

    private let feedURL = URL(string: "https://www.blazingfasttranscription.com/announcements.json")!
    private let dismissedKey = "dismissedAnnouncementIDs"
    private let checkInterval: TimeInterval = 4 * 60 * 60  // 4 hours
    private var timer: Timer?

    private init() {}

    /// Start checking on launch and every 4 hours while the app is running.
    func startPeriodicChecks() {
        checkForAnnouncements()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkForAnnouncements()
        }
    }

    func checkForAnnouncements() {
        let task = URLSession.shared.dataTask(with: feedURL) { [weak self] data, response, error in
            guard let self, let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            do {
                let feed = try JSONDecoder().decode(AnnouncementFeed.self, from: data)
                let dismissed = Set(UserDefaults.standard.stringArray(forKey: self.dismissedKey) ?? [])
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

                // Find first undismissed, version-eligible announcement
                guard let announcement = feed.announcements.first(where: { a in
                    !dismissed.contains(a.id) && a.isEligible(appVersion: appVersion)
                }) else { return }

                DispatchQueue.main.async {
                    self.show(announcement)
                }
            } catch {
                #if DEBUG
                print("[Announcements] Failed to decode feed: \(error)")
                #endif
            }
        }
        task.resume()
    }

    private func show(_ announcement: Announcement) {
        let alert = NSAlert()
        alert.messageText = announcement.title
        alert.informativeText = announcement.body
        alert.alertStyle = .informational

        if let label = announcement.buttonLabel, announcement.buttonURL != nil {
            alert.addButton(withTitle: label)
            alert.addButton(withTitle: "Dismiss")
        } else {
            alert.addButton(withTitle: "OK")
        }

        let response = alert.runModal()

        // Open URL if they clicked the action button
        if response == .alertFirstButtonReturn,
           let urlString = announcement.buttonURL,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        dismiss(announcement.id)
    }

    private func dismiss(_ id: String) {
        var dismissed = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        dismissed.append(id)
        UserDefaults.standard.set(dismissed, forKey: dismissedKey)
    }
}

// MARK: - Models

private struct AnnouncementFeed: Decodable {
    let announcements: [Announcement]
}

private struct Announcement: Decodable {
    let id: String
    let title: String
    let body: String
    let buttonLabel: String?
    let buttonURL: String?
    let minVersion: String?
    let maxVersion: String?

    func isEligible(appVersion: String) -> Bool {
        if let min = minVersion, appVersion.versionCompare(min) == .orderedAscending { return false }
        if let max = maxVersion, appVersion.versionCompare(max) == .orderedDescending { return false }
        return true
    }
}

private extension String {
    func versionCompare(_ other: String) -> ComparisonResult {
        compare(other, options: .numeric)
    }
}
