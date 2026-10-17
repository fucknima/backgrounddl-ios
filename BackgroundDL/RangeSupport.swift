import Foundation

struct ByteRange: Codable, Equatable {
    let start: Int64
    let end: Int64
    var length: Int64 { end - start + 1 }

    static func plan(total: Int64, count: Int) -> [ByteRange] {
        guard total > 0, count > 0, Int64(count) <= total else { return [] }
        let n = Int64(count)
        let width = total / n
        let extra = total % n
        var begin: Int64 = 0
        return (0..<count).map { i in
            let size = width + (Int64(i) < extra ? 1 : 0)
            let item = ByteRange(start: begin, end: begin + size - 1)
            begin += size
            return item
        }
    }
}

struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    init?(_ header: String) {
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = text.dropFirst(6)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let offsets = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard offsets.count == 2, let start = Int64(offsets[0]), let end = Int64(offsets[1]),
              start >= 0, end >= start, end < total else { return nil }
        self.start = start
        self.end = end
        self.total = total
    }

    func matches(_ chunk: ByteRange, totalBytes: Int64) -> Bool {
        start == chunk.start && end == chunk.end && total == totalBytes
    }
}

enum DownloadMode: String, CaseIterable, Identifiable {
    case stable, smart, fast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stable: return "稳定后台"
        case .smart: return "智能高速"
        case .fast: return "极速分段"
        }
    }
    var desiredParts: Int {
        switch self {
        case .stable: return 1
        case .smart: return 2
        case .fast: return 4
        }
    }
}
