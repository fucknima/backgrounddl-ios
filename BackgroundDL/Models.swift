import Foundation

enum DownloadSource: String, Codable {
    case direct
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
    var resumeDataBase64: String?

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var sourceLabel: String {
        switch source {
        case .direct: return "直链"
        case .browser: return "网页"
        }
    }
}

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
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "请输入有效的 HTTPS 下载链接。"
        case .unsupportedLink(let reason): return reason
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
