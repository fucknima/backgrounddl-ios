import Foundation
enum SharedLinkInbox {
    static let suite = "group.com.example.backgrounddl.shared"
    static let key = "pendingSharedWebLinks"
    static func takeNext() -> URL? {
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        var queue = defaults.stringArray(forKey: key) ?? []
        while !queue.isEmpty {
            let text = queue.removeFirst()
            defaults.set(queue, forKey: key)
            if let url = URL(string: text), url.host != nil,
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return url }
        }
        return nil
    }
}
