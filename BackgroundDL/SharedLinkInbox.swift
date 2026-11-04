import Foundation
enum SharedLinkInbox {
    static let suite = "group.com.example.backgrounddl.shared"
    static let key = "pendingSharedWebLinks"

    /// Drains the inbox and returns the most recent valid link. A stale entry
    /// must never shadow a link the user just shared.
    static func takeLatest() -> URL? {
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defaults.synchronize()
        let queue = defaults.stringArray(forKey: key) ?? []
        guard !queue.isEmpty else { return nil }
        defaults.removeObject(forKey: key)
        for text in queue.reversed() {
            if let url = URL(string: text), url.host != nil,
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return url }
        }
        return nil
    }
}
