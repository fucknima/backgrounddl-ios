import SwiftUI
import UIKit

final class DownloaderAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackgroundDownloader.shared
        BackgroundDownloader.shared.reconnect()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.backgroundCompletionHandler = completionHandler
        BackgroundDownloader.shared.reconnect()
    }
}

@main
struct BackgroundDLApp: App {
    @UIApplicationDelegateAdaptor(DownloaderAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
