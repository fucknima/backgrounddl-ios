import SwiftUI
import UIKit

final class DownloaderAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?
    static var segmentCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackgroundDownloader.shared
        if #available(iOS 26.0, *) {
            ContinuedDownloadProgress.shared.register()
        }
        Task { @MainActor in
            DownloadCoordinator.shared.reconnect()
            DownloadRetryManager.shared.resumePending()
        }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == SegmentedDownloader.identifier {
            Self.segmentCompletionHandler = completionHandler
            Task { @MainActor in SegmentedDownloader.shared.reconnect() }
            return
        }
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.backgroundCompletionHandler = completionHandler
        Task { @MainActor in
            DownloadCoordinator.shared.reconnect()
            DownloadRetryManager.shared.resumePending()
        }
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
