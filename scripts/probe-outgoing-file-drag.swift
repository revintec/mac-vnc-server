// Run from the repository root on an unlocked desktop with Accessibility access:
// xcrun swiftc -swift-version 6 scripts/probe-outgoing-file-drag.swift \
//   Sources/mac-vnc-server/{OutgoingFileDrag,MacInputController,MouseClickTracker,VirtualDisplayLayout,Logging}.swift \
//   -o /tmp/probe-outgoing-file-drag
// /tmp/probe-outgoing-file-drag
// Moves the pointer only over this probe's window. No VNC listener, capture,
// credentials, Finder manipulation, or general pasteboard changes are needed.
// A successful outgoing archive alone is insufficient: both source drags must
// finish, and the second ordinary drop must work in the same source instance.
import AppKit
import ApplicationServices

protocol InputController {
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout)
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool)
    func releaseKeys()
}

@MainActor private final class Destination: NSView {
    var performed = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true; layer?.backgroundColor = NSColor.systemGreen.cgColor
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { performed += 1; return true }
}

@MainActor private final class Probe: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let table = NSTableView()
    private let destination = Destination(frame: NSRect(x: 440, y: 30, width: 280, height: 260))
    private let input = MacInputController()
    private var previous: NSRunningApplication?
    private var fixture: URL!
    private var start = CGPoint.zero, end = CGPoint.zero
    private var began = 0, ended = 0, tick = 0
    private var releases = 0
    private var timer: Timer?
    private var receiver: AppKitOutgoingFileDrag?
    private var received = false
    var succeeded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            print("Accessibility access is required; no input sent."); exit(1)
        }
        previous = NSWorkspace.shared.frontmostApplication
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("vnc-drag-probe-\(UUID()).txt")
        do { try Data("temporary drag fixture".utf8).write(to: fixture) }
        catch { print(error); exit(1) }
        window = NSWindow(contentRect: NSRect(x: 120, y: 150, width: 760, height: 340),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "VNC outgoing drag regression probe (13 seconds)"
        window.isReleasedWhenClosed = false; window.level = .floating
        window.hidesOnDeactivate = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); column.width = 300
        table.addTableColumn(column); table.dataSource = self; table.delegate = self
        table.rowHeight = 40; table.headerView = nil
        table.frame = NSRect(x: 20, y: 30, width: 320, height: 260)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        window.contentView!.addSubview(table); window.contentView!.addSubview(destination)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func global(_ view: NSView, _ point: NSPoint) -> CGPoint {
            let p = window.convertPoint(toScreen: view.convert(point, to: nil))
            return CGPoint(x: p.x, y: NSScreen.screens[0].frame.height - p.y)
        }
        start = global(table, NSPoint(x: 140, y: 20))
        end = global(destination, NSPoint(x: 140, y: 130))
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Temporary file" }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { fixture as NSURL }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt point: NSPoint, forRowIndexes rows: IndexSet) { began += 1 }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        ended += 1; print("Source ended: operation=\(operation.rawValue)")
    }

    private func owned(_ point: CGPoint) -> Bool {
        var element: AXUIElement?, pid: pid_t = 0
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
        if let element { AXUIElementGetPid(element, &pid) }
        return pid == getpid()
    }
    private func send(_ mask: UInt8, _ point: CGPoint) {
        input.pointer(buttonMask: mask, x: 0, y: 0,
            layout: VirtualDisplayLayout(displays: [], origin: point, scale: 1, width: 1, height: 1))
    }
    private func advance() {
        tick += 1
        if tick == 15 || tick == 75 {
            guard owned(start), owned(end) else { print("Probe is obscured; stopping."); finish(); return }
            send(0, start)
        }
        if tick == 17 || tick == 77 { send(1, start) }
        if (20...23).contains(tick) || (80...99).contains(tick) {
            let f = Double(tick < 75 ? tick - 19 : tick - 79) / 20
            send(1, CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f))
        }
        if tick == 24 {
            receiver = AppKitOutgoingFileDrag()
            receiver!.start(nudge: { [weak self] in
                MainActor.assumeIsolated {
                    guard var p = CGEvent(source: nil)?.location else { return }
                    p.x += 1; self?.send(1, p)
                }
            }, release: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.releases += 1
                    if let p = CGEvent(source: nil)?.location { self.send(0, p) }
                }
            }, completion: { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .success(let urls) = result { self.received = urls == [self.fixture] }
                    else { print("Outgoing receiver failed: \(result)") }
                }
            })
        }
        if tick == 104 { send(0, end) }
        if tick == 125 { finish() }
    }
    private func finish() {
        timer?.invalidate(); receiver?.cancel(); input.releaseKeys()
        succeeded = began == 2 && ended == 2 && releases == 1 && received && destination.performed == 1
        print("RESULT began=\(began) ended=\(ended) archive=\(received) releases=\(releases) ordinaryDrops=\(destination.performed) passed=\(succeeded)")
        window?.close()
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        if NSApp.isActive { previous?.activate(options: []) }
        exit(succeeded ? 0 : 1)
    }
}

@main private struct Entry {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let probe = Probe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
        exit(probe.succeeded ? 0 : 1)
    }
}
