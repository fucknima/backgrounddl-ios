import Foundation
import GoogleSignIn
import UIKit
import Combine

struct PreparedDownload {
    let request: URLRequest
    let name: String
    let source: DownloadSource
}

private struct DriveMetadata: Decodable {
    let name: String
    let mimeType: String
    let capabilities: Capabilities?
    struct Capabilities: Decodable { let canDownload: Bool? }
}

private struct APIErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable { let message: String }
}

@MainActor
final class GoogleDriveService: ObservableObject {
    @Published private(set) var accountLabel = "未登录（Google Drive 文件需要授权）"
    private static let scope = "https://www.googleapis.com/auth/drive.readonly"

    private var clientID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !id.isEmpty, !id.hasPrefix("YOUR_") else { return nil }
        return id
    }

    private func configure() throws {
        guard let id = clientID else { throw DownloadError.googleNotConfigured }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: id)
    }

    func restore() async {
        guard (try? configure()) != nil else { return }
        if let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn() {
            accountLabel = user.profile?.email ?? "已登录 Google"
        }
    }

    func signIn() async throws {
        try configure()
        let controller = try presentationController()
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller)
        let user = result.user
        if !(user.grantedScopes ?? []).contains(Self.scope) {
            let updated = try await user.addScopes([Self.scope], presenting: controller)
            accountLabel = updated.user.profile?.email ?? "已登录 Google"
        } else {
            accountLabel = user.profile?.email ?? "已登录 Google"
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        accountLabel = "未登录（Google Drive 文件需要授权）"
    }

    func prepare(_ link: String) async throws -> PreparedDownload {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            throw DownloadError.invalidLink
        }
        guard let driveLink = try DriveFileLink.parse(url) else {
            // 对普通 URL 不加 Google 登录凭据。
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            let basename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let name = basename.isEmpty || basename == "/" ?
                "下载文件_\(UUID().uuidString.prefix(8))" : basename
            return PreparedDownload(request: request, name: name, source: .direct)
        }

        try configure()
        guard let user = GIDSignIn.sharedInstance.currentUser,
              (user.grantedScopes ?? []).contains(Self.scope) else {
            throw DownloadError.googleNotSignedIn
        }
        let fresh = try await user.refreshTokensIfNeeded()
        let token = fresh.accessToken.tokenString

        let id = driveLink.fileID
        var metadataURL = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        metadataURL.queryItems = [
            URLQueryItem(name: "fields", value: "name,mimeType,capabilities(canDownload)"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        var metadataRequest = URLRequest(url: metadataURL.url!)
        metadataRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let key = driveLink.resourceKey {
            metadataRequest.setValue("\(id)/\(key)", forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
        }
        let (data, response) = try await URLSession.shared.data(for: metadataRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
                ?? String(decoding: data.prefix(250), as: UTF8.self)
            throw DownloadError.http(status, message)
        }
        guard let info = try? JSONDecoder().decode(DriveMetadata.self, from: data) else {
            throw DownloadError.invalidResponse
        }
        if info.capabilities?.canDownload == false { throw DownloadError.googleNoPermission }
        if info.mimeType == "application/vnd.google-apps.folder" {
            throw DownloadError.unsupportedLink("这是文件夹，不是单个文件。暂不支持批量下载文件夹。")
        }

        var mediaURL: URL
        var filename = info.name
        switch info.mimeType {
        case "application/vnd.google-apps.document":
            mediaURL = Self.exportURL(id: id,
                mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
            filename = Self.appendingExtension(filename, ext: "docx")
        case "application/vnd.google-apps.spreadsheet":
            mediaURL = Self.exportURL(id: id,
                mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            filename = Self.appendingExtension(filename, ext: "xlsx")
        case "application/vnd.google-apps.presentation":
            mediaURL = Self.exportURL(id: id,
                mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation")
            filename = Self.appendingExtension(filename, ext: "pptx")
        case "application/vnd.google-apps.drawing":
            mediaURL = Self.exportURL(id: id, mime: "application/pdf")
            filename = Self.appendingExtension(filename, ext: "pdf")
        default:
            if info.mimeType.hasPrefix("application/vnd.google-apps.") {
                throw DownloadError.unsupportedLink("此 Google Workspace 文件类型暂不支持导出。")
            }
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
            components.queryItems = [URLQueryItem(name: "alt", value: "media"),
                                     URLQueryItem(name: "supportsAllDrives", value: "true")]
            mediaURL = components.url!
        }
        var request = URLRequest(url: mediaURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let key = driveLink.resourceKey {
            request.setValue("\(id)/\(key)", forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
        }
        request.timeoutInterval = 60
        return PreparedDownload(request: request, name: filename, source: .googleDrive)
    }

    private static func exportURL(id: String, mime: String) -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)/export")!
        components.queryItems = [URLQueryItem(name: "mimeType", value: mime)]
        return components.url!
    }

    private static func appendingExtension(_ name: String, ext: String) -> String {
        return (name as NSString).pathExtension.lowercased() == ext ? name : "\(name).\(ext)"
    }

    private func presentationController() throws -> UIViewController {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard var controller = window?.rootViewController else {
            throw DownloadError.unsupportedLink("当前无法弹出 Google 登录页面，请重新打开 App。")
        }
        while let next = controller.presentedViewController { controller = next }
        return controller
    }
}
