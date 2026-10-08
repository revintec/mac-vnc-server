import Foundation

/// Supported representations of one pasteboard generation. A nil payload is a
/// deferred promise; an empty item list is an explicit clipboard clear.
struct ClipboardContent: Equatable, Sendable {
    struct Flavor: Equatable, Sendable {
        let type: String
        let data: Data?
    }

    static let textType = "public.utf8-plain-text"
    static let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg"]
    static let supportedTypes = imageTypes.union([textType])
    static let empty = ClipboardContent(items: [])
    let items: [[Flavor]]

    init(items: [[Flavor]]) {
        // Representation ordering can change during AppKit round trips.
        self.items = items.filter { !$0.isEmpty }.map { $0.sorted { $0.type < $1.type } }
    }

    static func text(_ value: String) -> ClipboardContent {
        value.isEmpty ? .empty : ClipboardContent(items: [[Flavor(type: textType, data: Data(value.utf8))]])
    }

    var resolved: ClipboardContent { ClipboardContent(items: items.map { $0.filter { $0.data != nil } }) }
    var hasPromises: Bool { items.contains { $0.contains { $0.data == nil } } }
    var hasImages: Bool { items.contains { $0.contains { Self.imageTypes.contains($0.type) } } }
    var payloadBytes: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + ($1.data?.count ?? 0) } } }
    var text: String? {
        if items.isEmpty { return "" }
        for item in items {
            for flavor in item where flavor.type == Self.textType {
                if let data = flavor.data, let text = String(data: data, encoding: .utf8) { return text }
            }
        }
        return nil
    }
}
