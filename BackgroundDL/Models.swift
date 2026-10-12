import Foundation

// 保存到磁盘的任务信息。Token 不写入这里。
enum DownloadSource: String, Codable {
    case direct
    case googleDrive
    case browser
}

enum DownloadStatus: String, Codable {
    case running
    case paused
    case completed
    case failed
    case cancelled
}

struct DownloadItem: Identifiable, Codable {
    var id: UUID
    var originalURL: String
    var filename: String
    var source: DownloadSource
    var status: DownloadStatus
    var downloadedBytes: Int64
    var totalBytes: Int64
    var errorMessage: String?
    var savedFilename: String?
    var createdAt: Date

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

// URLSessionTask.taskDescription 会跟随系统后台任务保存，用于恢复关联。
struct TaskMarker: Codable {
    let id: UUID
    let filename: String
    let source: DownloadSource

    var text: String {
        let bytes = (try? JSONEncoder().encode(self)) ?? Data()
        return bytes.base64EncodedString()
    }

    static func decode(_ text: String?) -> TaskMarker? {
        guard let text, let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum DownloadError: LocalizedError {
    case invalidLink
    case unsupportedLink(String)
    case googleNotConfigured
    case googleNotSignedIn
    case googleNoPermission
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "请输入有效的 HTTPS 下载链接。"
        case .unsupportedLink(let reason): return reason
        case .googleNotConfigured:
            return "请先在 Info.plist 中填入 Google iOS OAuth Client ID 和反向 URL Scheme。"
        case .googleNotSignedIn: return "先点击「登录 Google」授权访问云端硬盘。"
        case .googleNoPermission: return "该 Google Drive 文件没有下载权限。"
        case .http(let code, let message): return "服务器返回 HTTP \(code)：\(message)"
        case .invalidResponse: return "服务器没有返回有效的文件信息。"
        }
    }
}

extension Int64 {
    var readableSize: String {
        guard self >= 0 else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
