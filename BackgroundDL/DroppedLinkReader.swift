import Foundation
import UniformTypeIdentifiers

/// Decodes the *contents* of an item provider, not just its advertised UTI.
/// Safari and other sources may vend "public.url" as a URL object, UTF-8
/// bytes, a property list, or a generic item. Each representation is optional.
enum DroppedLinkCodec {
    static let maximumBytes = 128_000

    static func resolve(_ url: URL) -> URL? {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil, url.user == nil, url.password == nil {
            return url
        }
        guard url.isFileURL else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let length = attributes[.size] as? NSNumber,
              length.intValue >= 0 && length.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> URL? {
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }

        // On iOS, dragging an URL sometimes produces a binary/XML .webloc.
        if let property = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = property as? [String: Any],
           let value = dictionary["URL"] as? String,
           let url = extract(value) {
            return url
        }

        // Some URL representations contain a secure archived NSURL.
        if let value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data),
           let url = resolve(value as URL) {
            return url
        }

        if let text = String(data: data, encoding: .utf8),
           let url = extract(text) { return url }
        if let text = String(data: data, encoding: .utf16),
           let url = extract(text) { return url }
        return nil
    }

    static func decode(item: NSSecureCoding?) -> URL? {
        guard let item else { return nil }
        if let url = item as? URL { return resolve(url) }
        if let url = item as? NSURL { return resolve(url as URL) }
        if let text = item as? String { return extract(text) }
        if let text = item as? NSString { return extract(text as String) }
        if let data = item as? Data { return decode(data) }
        if let data = item as? NSData { return decode(data as Data) }
        if let attributed = item as? NSAttributedString { return extract(attributed.string) }
        return nil
    }

    static func extract(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let valid = validated(url) { return valid }
        if let urlLine = trimmed.split(whereSeparator: \.isNewline).first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("url=")
        }) {
            let line = String(urlLine).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: String(line.dropFirst(4))), let valid = validated(url) {
                return valid
            }
        }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ), let match = detector.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let url = match.url else { return nil }
        return validated(url)
    }

    private static func validated(_ url: URL) -> URL? {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
        url.host != nil && url.user == nil && url.password == nil ? url : nil
    }
}

@MainActor
private final class DroppedLinkResolution {
    private var remaining: Int
    private var settled = false
    private let note: (String) -> Void
    private let finish: (URL?) -> Void

    init(attempts: Int, note: @escaping (String) -> Void, finish: @escaping (URL?) -> Void) {
        remaining = attempts
        self.note = note
        self.finish = finish
    }

    func report(_ url: URL?, method: String, detail: String) {
        guard !settled else { return }
        if let url {
            settled = true
            note("拖放解析成功：\(method) → \(url.host ?? "网页")")
            finish(url)
        } else {
            remaining -= 1
            note("拖放读取未匹配：\(method)（\(detail)）")
            if remaining == 0 {
                settled = true
                finish(nil)
            }
        }
    }
}

/// Starts ALL registered representation requests while the onDrop callback is
/// still executing. A failed public.url request cannot suppress the plain-text
/// fallback, which Safari often advertises alongside the URL representation.
@MainActor
enum DroppedLinkReader {
    static func load(
        providers: [NSItemProvider],
        note: @escaping (String) -> Void,
        completion: @escaping (URL?) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.canLoadObject(ofClass: URL.self) ||
            $0.canLoadObject(ofClass: String.self) ||
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
        }) else {
            note("拖放没有支持的 URL 或文本表示")
            return false
        }

        let useURLObject = provider.canLoadObject(ofClass: URL.self)
        let useStringObject = provider.canLoadObject(ofClass: String.self)
        let useURLData = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        let usePlainData = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
        let useURLItem = useURLData

        let attempts = [useURLObject, useStringObject, useURLData, usePlainData, useURLItem]
            .filter { $0 }.count
        guard attempts > 0 else { return false }
        note("拖放读取策略：URL对象=\(useURLObject)，文本对象=\(useStringObject)，URL数据=\(useURLData)，文本数据=\(usePlainData)")
        let state = DroppedLinkResolution(attempts: attempts, note: note, finish: completion)

        if useURLObject {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                DispatchQueue.main.async {
                    state.report(url.flatMap(DroppedLinkCodec.resolve), method: "URL对象",
                                 detail: error == nil ? "无有效 URL" : "读取错误")
                }
            }
        }
        if useStringObject {
            _ = provider.loadObject(ofClass: String.self) { text, error in
                DispatchQueue.main.async {
                    state.report(text.flatMap(DroppedLinkCodec.extract), method: "文本对象",
                                 detail: error == nil ? "无有效网址" : "读取错误")
                }
            }
        }
        if useURLData {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, error in
                DispatchQueue.main.async {
                    state.report(data.flatMap(DroppedLinkCodec.decode), method: "public.url 数据",
                                 detail: error == nil ? "\(data?.count ?? 0)B" : "读取错误")
                }
            }
        }
        if usePlainData {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, error in
                DispatchQueue.main.async {
                    state.report(data.flatMap(DroppedLinkCodec.decode), method: "UTF-8文本数据",
                                 detail: error == nil ? "\(data?.count ?? 0)B" : "读取错误")
                }
            }
        }
        if useURLItem {
            _ = provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    let typeName = item.map { String(describing: type(of: $0)) } ?? "空"
                    state.report(DroppedLinkCodec.decode(item: item), method: "URL原始对象",
                                 detail: error == nil ? typeName : "读取错误")
                }
            }
        }
        return true
    }
}
