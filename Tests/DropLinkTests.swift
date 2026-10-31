import Foundation
import UniformTypeIdentifiers

@main
struct DropLinkVerification {
    @MainActor static func main() throws {
        func require(_ predicate: @autoclosure () -> Bool, _ description: String) {
            if !predicate() { fatalError("FAIL: \(description)") }
        }
        let expected = "https://example.org/releases/file.zip?token=redacted"
        func same(_ value: URL?, _ label: String) {
            require(value?.absoluteString == expected, label)
        }

        // Real representations observed in cross-app URL drops.
        same(DroppedLinkCodec.extract(expected), "plain URL string")
        same(DroppedLinkCodec.extract("Download:\n\(expected)\n"), "URL embedded in text")
        same(DroppedLinkCodec.extract("[InternetShortcut]\nURL=\(expected)\n"), "Windows URL document")
        same(DroppedLinkCodec.decode(Data(expected.utf8)), "public.utf8-plain-text")
        same(DroppedLinkCodec.decode(expected.data(using: .utf16)!), "UTF-16 URL data")
        let webloc = try PropertyListSerialization.data(
            fromPropertyList: ["URL": expected], format: .binary, options: 0
        )
        same(DroppedLinkCodec.decode(webloc), "binary .webloc")
        let archivedURL = try NSKeyedArchiver.archivedData(
            withRootObject: NSURL(string: expected)!, requiringSecureCoding: true
        )
        same(DroppedLinkCodec.decode(archivedURL), "secure NSURL archive")
        same(DroppedLinkCodec.decode(item: expected as NSString), "NSString object")
        same(DroppedLinkCodec.decode(item: NSURL(string: expected)!), "NSURL object")
        same(DroppedLinkCodec.decode(item: ["URL": expected] as NSDictionary), "webloc dictionary item")
        require(DroppedLinkCodec.extract("javascript:alert(1)") == nil, "unsafe JS scheme rejected")
        require(DroppedLinkCodec.extract("file:///etc/passwd") == nil, "arbitrary file URL rejected")
        require(DroppedLinkCodec.decode(Data(repeating: 1, count: 128_001)) == nil, "oversized payload rejected")
        print("PASS: URL/text/plist/archived NSURL decoding and safety")

        // Use actual Foundation NSItemProvider implementations (not a mocked parser).
        // Launch all representation requests using exactly the app's production reader.
        @MainActor func resolve(_ label: String, _ providers: [NSItemProvider]) -> (URL?, [String]) {
            var finished = false
            var actual: URL?
            var notes: [String] = []
            let started = DroppedLinkReader.load(providers: providers, note: {
                notes.append($0)
            }, completion: {
                actual = $0
                finished = true
            })
            require(started, "\(label): reader accepted provider")
            let limit = Date().addingTimeInterval(max(8, DroppedLinkReader.deadline + 3))
            while !finished && Date() < limit {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            require(finished, "\(label): reader callback arrived")
            return (actual, notes)
        }

        @MainActor func checkProvider(_ label: String, _ provider: NSItemProvider) {
            checkProviders(label, [provider])
        }

        @MainActor func checkProviders(_ label: String, _ providers: [NSItemProvider]) {
            let (actual, notes) = resolve(label, providers)
            require(actual?.absoluteString == expected,
                    "\(label): resolved URL (\(notes.joined(separator: "; ")))")
            print("PASS: NSItemProvider \(label)")
        }

        @MainActor func checkNoLink(_ label: String, _ providers: [NSItemProvider]) {
            let (actual, notes) = resolve(label, providers)
            require(actual == nil, "\(label): no URL (\(notes.joined(separator: "; ")))")
            print("PASS: NSItemProvider \(label)")
        }

        let urlObject = NSItemProvider(object: NSURL(string: expected)!)
        checkProvider("NSURL object", urlObject)
        let textObject = NSItemProvider(object: expected as NSString)
        checkProvider("NSString plain text", textObject)

        let urlBytes = NSItemProvider()
        urlBytes.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { complete in
            complete(Data(expected.utf8), nil)
            return nil
        }
        checkProvider("public.url data", urlBytes)

        let dual = NSItemProvider()
        // A malformed URL representation must NOT stop valid UTF-8 text fallback.
        dual.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { complete in
            complete(Data([0x00, 0x01]), nil)
            return nil
        }
        dual.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { complete in
            complete(Data(expected.utf8), nil)
            return nil
        }
        checkProvider("malformed URL + valid plain-text fallback", dual)

        // The link may sit on a later item of a multi-item drag.
        let label = NSItemProvider(object: "Release notes" as NSString)
        let later = NSItemProvider()
        later.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { complete in
            complete(Data(expected.utf8), nil)
            return nil
        }
        checkProviders("second item of a multi-item drag", [label, later])

        // A drop with only a never-answering representation must finish as empty
        // instead of leaving the handler silent forever.
        let neverAnswers = NSItemProvider()
        neverAnswers.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { _ in
            Progress(totalUnitCount: 1)
        }
        checkNoLink("never-answering representation", [neverAnswers])

    }
}
