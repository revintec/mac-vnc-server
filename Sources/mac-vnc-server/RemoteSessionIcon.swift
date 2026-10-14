import AppKit

@MainActor
enum RemoteSessionIcon {
    static let remoteDisplay: NSImage? = {
        let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Remote VNC")
        image?.isTemplate = true
        return image
    }()
    static let eyeBright = redEye(alpha: 1)
    static let eyeDim = redEye(alpha: 0.4)

    private static func redEye(alpha: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Desktop visible on physical display") else {
            return nil
        }
        // NSStatusBarButton's template rendering can ignore contentTintColor
        // (including in Tahoe's Control Center hosted status items). Bake the
        // color into a non-template image so both blink phases stay red.
        let image = NSImage(size: symbol.size)
        let rect = NSRect(origin: .zero, size: symbol.size)
        image.lockFocus()
        symbol.draw(in: rect)
        NSColor.systemRed.withAlphaComponent(alpha).setFill()
        rect.fill(using: .sourceIn)
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = symbol.accessibilityDescription
        return image
    }
}
