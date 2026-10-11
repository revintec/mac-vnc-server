import AppKit
import Foundation

/// The RFB reader and main-thread drag source share this gate. Once an up,
/// exit, disconnect, or Observe is seen, completion can never start a late drag.
final class TransferGesture: @unchecked Sendable {
    let batch: UUID
    private let lock = NSLock()
    private var held = true
    private var sendDragEvent: (@Sendable (TransferDragEvent) -> Void)?
    private let input: InputController
    private var point: CGPoint
    private let ended: @Sendable () -> Void
    init(batch: UUID, input: InputController, ended: @escaping @Sendable () -> Void) {
        self.batch = batch; self.input = input; self.ended = ended
        point = CGEvent(source: nil)?.location ?? .zero
    }
    func pointer(mask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) -> Bool {
        let released = lock.withLock { () -> Bool? in
            guard held else { return nil }
            point = layout.globalPoint(framebufferX: Int(x), framebufferY: Int(y))
            // CoreDrag also observes WindowServer's held-button state. Keep it
            // in sync while delivering the drag's events to its own AppKit source.
            input.pointer(buttonMask: sendDragEvent == nil ? 0 : mask, x: x, y: y, layout: layout)
            let released = mask & 1 == 0
            sendDragEvent?(released ? .drop(point) : .move(point))
            if released { held = false; sendDragEvent = nil }
            return released
        }
        if released == true { ended() }
        return released != nil
    }
    @MainActor func startIfHeld(_ start: (CGPoint, () -> Void) throws -> @Sendable (TransferDragEvent) -> Void) rethrows -> Bool {
        try lock.withLock {
            guard held, sendDragEvent == nil else { return false }
            let layout = VirtualDisplayLayout(displays: [], origin: point, scale: 1, width: 1, height: 1)
            sendDragEvent = try start(point) {
                input.pointer(buttonMask: 0, x: 0, y: 0, layout: layout)
                input.pointer(buttonMask: 1, x: 0, y: 0, layout: layout)
            }
            return true
        }
    }
    func cancel() {
        let notify = lock.withLock { () -> Bool in
            guard held else { return false }
            held = false
            sendDragEvent?(.cancel)
            if sendDragEvent != nil {
                let layout = VirtualDisplayLayout(displays: [], origin: point, scale: 1, width: 1, height: 1)
                input.pointer(buttonMask: 0, x: 0, y: 0, layout: layout)
            }
            sendDragEvent = nil
            return true
        }
        if notify { ended() }
    }
}

final class TransferInbox: @unchecked Sendable {
    let store: TransferStore
    let present: @Sendable (TransferGesture) -> Void
    let reportError: @Sendable (String) -> Void
    private let lock = NSLock()
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    init(store: TransferStore, reportError: @escaping @Sendable (String) -> Void = { _ in },
         present: @escaping @Sendable (TransferGesture) -> Void = { _ in }) {
        self.store = store; self.present = present; self.reportError = reportError
    }
    func register(_ gesture: TransferGesture, cancel: @escaping @Sendable () -> Void) {
        lock.withLock { cancellations[gesture.batch] = cancel }
        present(gesture)
    }
    func cancel(_ id: UUID) {
        if let cancel = lock.withLock({ cancellations[id] }) { DispatchQueue.global(qos: .utility).async(execute: cancel) }
    }
    func canCancel(_ id: UUID) -> Bool { lock.withLock { cancellations[id] != nil } }
    func finished(_ id: UUID) { _ = lock.withLock { cancellations.removeValue(forKey: id) } }
}

@MainActor
final class TransferPanel: NSObject, @preconcurrency NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store: TransferStore
    private let logger: ServerLogger
    private var inbox: TransferInbox!
    private var batches: [TransferStore.Batch] = []
    private var gestures: [UUID: TransferGesture] = [:]
    private var dragWindows: [UUID: NSWindow] = [:]
    private let window: NSPanel
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Drag files into Screen Sharing. Keep holding to continue when ready, or drag completed files from this list.")
    private lazy var cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSelected))
    private let partial = NSButton(checkboxWithTitle: "Use completed items from a failed transfer", target: nil, action: nil)
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var tableDragging = false
    private var nextCleanup = Date().addingTimeInterval(60)
    init(store: TransferStore, logger: ServerLogger = ServerLogger(verbose: false)) {
        self.store = store; self.logger = logger
        window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 600, height: 340),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        window.title = "Received Files — mac-vnc-server"
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false; window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        window.contentMinSize = NSSize(width: 540, height: 320)
        table.addTableColumn(NSTableColumn(identifier: .init("transfers")))
        table.headerView = nil; table.rowHeight = 52; table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        stack.addArrangedSubview(partial)
        let buttons = NSStackView(); buttons.spacing = 8
        for (title, action) in [("Cancel", #selector(cancelSelected)), ("Reveal in Finder", #selector(reveal)), ("Save a Copy…", #selector(saveCopy)), ("Remove…", #selector(removeSelected))] {
            buttons.addArrangedSubview(title == "Cancel" ? cancelButton : NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)
        let note = NSTextField(wrappingLabelWithString: "Files used in a drag or opened are kept until you remove them. Changes here do not sync back to the client.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "VNC Files"; statusItem?.button?.target = self; statusItem?.button?.action = #selector(show)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    func makeInbox() -> TransferInbox {
        inbox = TransferInbox(store: store, reportError: { [weak self] message in
            DispatchQueue.main.async { self?.status.stringValue = message; self?.show() }
        }) { [weak self] gesture in
            DispatchQueue.main.async { self?.received(gesture) }
        }
        return inbox
    }
    @objc func show() { window.orderFrontRegardless() }
    private func received(_ gesture: TransferGesture) {
        gestures[gesture.batch] = gesture
        // Do not activate the panel: keep the user's intended app in front.
        show(); refresh()
    }
    private func refresh() {
        do {
            if Date() >= nextCleanup {
                nextCleanup = Date().addingTimeInterval(60)
                DispatchQueue.global(qos: .utility).async { [store] in try? store.clean() }
            }
            let next = try store.snapshot()
            if !tableDragging && next.map(\.updated) != batches.map(\.updated) {
                let selection = Set(selected.map(\.id))
                batches = next; table.reloadData()
                table.selectRowIndexes(IndexSet(batches.indices.filter { selection.contains(batches[$0].id) }), byExtendingSelection: false)
            }
            updateCancelButton()
            for batch in batches where !batch.isActive {
                inbox?.finished(batch.id)
                guard let gesture = gestures.removeValue(forKey: batch.id) else { continue }
                guard batch.isComplete else { gesture.cancel(); continue }
                let urls = try store.urls(batch.id)
                guard !urls.isEmpty else { continue }
                let started = try gesture.startIfHeld { [self] point, press in
                    try store.retain(batch.id)
                    return startDrag(gesture: gesture, urls: urls, point: point, press: press)
                }
                logger.verbose("Apple staged drag ready: batch=\(batch.id) continued=\(started) elapsed_ms=\(Int(Date().timeIntervalSince(batch.created) * 1000))")
                if !started { status.stringValue = "Transfer complete. Drag the completed row into an app." }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func startDrag(gesture: TransferGesture, urls: [URL], point: CGPoint, press: () -> Void) -> @Sendable (TransferDragEvent) -> Void {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let location = NSPoint(x: point.x, y: screenHeight - point.y)
        let source = TransferDragSource(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let surface = NSWindow(contentRect: NSRect(x: location.x - 20, y: location.y - 20, width: 40, height: 40),
                               styleMask: .borderless, backing: .buffered, defer: false)
        surface.isReleasedWhenClosed = false; surface.isOpaque = false; surface.backgroundColor = .clear
        surface.level = .popUpMenu; surface.contentView = source; surface.orderFrontRegardless()
        dragWindows[gesture.batch] = surface
        source.finished = { [weak self, logger] operation in
            logger.verbose("Apple staged drag ended: batch=\(gesture.batch) operation=\(operation.rawValue)")
            DispatchQueue.main.async { [weak self] in
                gesture.cancel()
                self?.dragWindows.removeValue(forKey: gesture.batch)?.close()
            }
        }
        press()
        source.start(urls: urls)
        logger.verbose("Apple staged drag tracking: batch=\(gesture.batch) input=appkit")
        status.stringValue = "Files ready. Continue moving to the target, then release to drop."
        return { [weak source] event in
            DispatchQueue.main.async { source?.receive(event) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { batches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let batch = batches[row]
        let names = batch.items.map(\.name).joined(separator: ", ")
        let complete = batch.items.filter { $0.state == .complete }.count
        let bytes = ByteCountFormatter.string(fromByteCount: batch.items.reduce(0) { $0 + $1.bytes }, countStyle: .file)
        let detail = batch.isComplete ? "Ready to drag · \(bytes)\(batch.retained ? " · Kept" : "")"
            : batch.isActive ? "Receiving · \(complete)/\(batch.items.count) complete · \(bytes)"
            : "\(complete)/\(batch.items.count) complete · \(batch.items.compactMap(\.error).first ?? "Transfer ended")"
        let label = NSTextField(wrappingLabelWithString: names + "\n" + detail)
        label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2
        let icon = NSImageView()
        if let path = batch.items.first?.relativePath {
            icon.image = NSWorkspace.shared.icon(forFile: store.destination(batch.id).appendingPathComponent(path).path)
        } else { icon.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Receiving") }
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let row = NSStackView(views: [icon, label]); row.spacing = 8
        return row
    }
    private var selected: [TransferStore.Batch] { table.selectedRowIndexes.compactMap { batches.indices.contains($0) ? batches[$0] : nil } }
    private func selectedURLs() throws -> [URL] {
        try selected.flatMap { batch in
            let urls = try store.urls(batch.id, allowPartial: partial.state == .on)
            if !urls.isEmpty { try store.retain(batch.id) }
            return urls
        }
    }
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        do {
            let rows = rowIndexes.map { batches[$0] }
            let groups = try rows.map { try store.urls($0.id, allowPartial: partial.state == .on) }
            guard groups.allSatisfy({ !$0.isEmpty }) else { return false }
            for row in rows { try store.retain(row.id) }
            pasteboard.clearContents()
            return pasteboard.writeObjects(groups.flatMap { $0 }.map { $0 as NSURL })
        } catch { status.stringValue = error.localizedDescription; return false }
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) { tableDragging = true }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { tableDragging = false; refresh() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateCancelButton() }
    private func updateCancelButton() { cancelButton.isEnabled = selected.contains { $0.isActive && inbox?.canCancel($0.id) == true } }
    @objc private func cancelSelected() { for batch in selected where batch.isActive { inbox.cancel(batch.id) } }
    @objc private func reveal() {
        guard !selected.isEmpty else {
            if !NSWorkspace.shared.open(store.options.root) {
                status.stringValue = "Could not open the transfer folder in Finder."
            }
            return
        }
        do { NSWorkspace.shared.activateFileViewerSelecting(try selectedURLs()) }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func saveCopy() {
        do {
            let urls = try selectedURLs(); guard !urls.isEmpty else { return }
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.prompt = "Save Copies"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let destination = panel.url else { return }
                DispatchQueue.global(qos: .utility).async {
                    do {
                        for url in urls {
                            let staging = destination.appendingPathComponent(".mac-vnc-copy-\(UUID())", isDirectory: true)
                            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                            defer { try? FileManager.default.removeItem(at: staging) }
                            let copy = staging.appendingPathComponent(url.lastPathComponent)
                            try FileManager.default.copyItem(at: url, to: copy)
                            _ = try TransferStore.publish(source: copy, directory: destination, name: url.lastPathComponent)
                        }
                    } catch { DispatchQueue.main.async { self?.status.stringValue = error.localizedDescription } }
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func removeSelected() {
        let ids = selected.filter { !$0.isActive }.map(\.id); guard !ids.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Remove these received copies?"
        alert.informativeText = "Apps may still refer to these files. Client originals are unaffected."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do { for id in ids { try store.remove(id) }; refresh() }
            catch { status.stringValue = error.localizedDescription }
        }
    }
}
