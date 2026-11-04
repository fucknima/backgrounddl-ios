import UIKit

/// Detects a web link on the general pasteboard without triggering the system
/// paste banner. `detectValues` is the privacy-preserving API: it returns the
/// recognized URL value, not the raw pasteboard contents.
@MainActor
final class ClipboardLinkWatcher {
    static let shared = ClipboardLinkWatcher()

    private let countKey = "bgdl.clipboard.lastChangeCount"
    private var isChecking = false

    private init() {}

    func check(handler: @escaping (URL) -> Void) {
        guard !isChecking else { return }
        let pasteboard = UIPasteboard.general
        let count = pasteboard.changeCount
        let defaults = UserDefaults.standard
        guard count != defaults.integer(forKey: countKey) else { return }

        isChecking = true
        pasteboard.detectValues(for: [\.probableWebURL]) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false
                defaults.set(count, forKey: self.countKey)
                guard case let .success(values) = result,
                      let url = URL(string: values.probableWebURL),
                      Self.isWebLink(url) else { return }
                handler(url)
            }
        }
    }

    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host != nil && url.user == nil && url.password == nil
    }
}
