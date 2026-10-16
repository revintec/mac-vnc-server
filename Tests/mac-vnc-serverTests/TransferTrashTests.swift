import AppKit
import Foundation
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct TransferTrashTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-trash-test-\(UUID())") }
    private func publish(_ store: TransferStore, batch: UUID, name: String, content: String) throws -> URL {
        let receive = try store.receive(batch: batch, name: name)
        try store.accept(receive, bytes: Int64(content.utf8.count) + 1_024, dataBytes: Int64(content.utf8.count))
        try Data(content.utf8).write(to: receive.staging.appendingPathComponent(name))
        return try store.complete(receive, name: name)
    }

    @Test func trashPersistsRemovalTimeAndFilesUntilRestored() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let batch = try store.begin(names: ["report.txt"])
        let file = try publish(store, batch: batch.id, name: "report.txt", content: "report contents")
        let manifest = store.directory(batch.id).appendingPathComponent("manifest.json")
        // Existing manifests have no removedAt field and remain in Received Files.
        #expect(try store.snapshot().first?.removedAt == nil)
        #expect(try store.snapshot(inTrash: true).isEmpty)
        let before = Date()
        try store.remove(batch.id)
        let removed = try #require(store.snapshot(inTrash: true).first)
        let removedAt = try #require(removed.removedAt)
        #expect(removedAt >= before && removedAt <= Date())
        #expect(try store.snapshot().isEmpty)
        #expect(try store.urls(batch.id, allowPartial: true).isEmpty)
        #expect(try store.revealURLs(batch.id) == [file])
        #expect(try String(contentsOf: file, encoding: .utf8) == "report contents")
        try store.remove(batch.id)
        #expect(try store.snapshot(inTrash: true).first?.removedAt == removedAt)

        var aged = removed
        aged.updated = Date().addingTimeInterval(-90_000)
        aged.retained = false // Trash itself prevents expiry, independently of retention.
        aged.items[0].storageBytes = 1_048_576
        try JSONEncoder().encode(aged).write(to: manifest, options: .atomic)
        let reopened = try TransferStore(options: .init(root: root))
        #expect(try reopened.snapshot().isEmpty)
        #expect(try reopened.snapshot(inTrash: true).first?.removedAt == removedAt)
        try reopened.restore(batch.id)
        let restored = try #require(reopened.snapshot().first)
        #expect(restored.removedAt == nil && restored.retained)
        #expect(restored.items.map(\.state) == removed.items.map(\.state))
        #expect(restored.items.map(\.relativePath) == removed.items.map(\.relativePath))
        #expect(try reopened.urls(batch.id) == [file])
        #expect(try reopened.snapshot(inTrash: true).isEmpty)
    }

    @Test func trashTotalsCountItemsAcrossTransfersAndExcludeQuotaOverhead() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let first = try store.begin(names: ["a", "b"])
        _ = try publish(store, batch: first.id, name: "a", content: "1234")
        _ = try publish(store, batch: first.id, name: "b", content: "56789")
        let second = try store.begin(names: ["c"])
        let moved = try publish(store, batch: second.id, name: "c", content: "moved outside Trash")
        let destination = root.appendingPathComponent("finder-result")
        try store.finderMoveAccepted(second.id, urls: [moved])
        try FileManager.default.moveItem(at: moved, to: destination)
        try store.remove(first.id)
        try store.remove(second.id)
        let trash = try store.snapshot(inTrash: true)
        #expect(trash.map(\.id) == [second.id, first.id])
        let summary = TransferStore.TrashSummary(batches: trash)
        #expect(summary.transferCount == 2 && summary.itemCount == 3)
        #expect(summary.dataBytes == 9)
        try store.restore(first.id)
        let afterRestore = TransferStore.TrashSummary(batches: try store.snapshot(inTrash: true))
        #expect(afterRestore.transferCount == 1 && afterRestore.itemCount == 1 && afterRestore.dataBytes == 0)
        try store.deletePermanently(second.id)
        let empty = TransferStore.TrashSummary(batches: try store.snapshot(inTrash: true))
        #expect(empty.transferCount == 0 && empty.itemCount == 0 && empty.dataBytes == 0)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "moved outside Trash")
    }

    @Test func permanentDeletionRequiresTrashAndWaitsForFinder() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let batch = try store.begin(names: ["file"])
        #expect(throws: (any Error).self) { try store.remove(batch.id) }
        let file = try publish(store, batch: batch.id, name: "file", content: "kept")
        #expect(throws: (any Error).self) { try store.deletePermanently(batch.id) }
        try store.finderMoveAccepted(batch.id, urls: [file])
        try store.remove(batch.id)
        #expect(throws: (any Error).self) { try store.deletePermanently(batch.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
        let destination = root.appendingPathComponent("finder-result")
        try FileManager.default.moveItem(at: file, to: destination)
        try store.deletePermanently(batch.id)
        #expect(!FileManager.default.fileExists(atPath: store.directory(batch.id).path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "kept")
    }

    @Test func restoringAndDeletingSymlinksDoesNotTouchTheirTargets() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let target = root.appendingPathComponent("target")
        try Data("original".utf8).write(to: target)
        let batch = try store.begin(names: ["link"])
        let receive = try store.receive(batch: batch.id, name: "link")
        try FileManager.default.createSymbolicLink(atPath: receive.staging.appendingPathComponent("link").path, withDestinationPath: target.path)
        let link = try store.complete(receive, name: "link")
        try store.remove(batch.id)
        try store.restore(batch.id)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        try store.remove(batch.id)
        try store.deletePermanently(batch.id)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
    }
}

@MainActor
@Suite(.serialized)
struct TransferPanelTests {
    @Test func commandASelectsAllRowsWhenAButtonHasFocus() throws {
        _ = NSApplication.shared
        let panel = TransferListPanel(contentRect: .init(x: 0, y: 0, width: 640, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let table = NSTableView(frame: .init(x: 0, y: 40, width: 600, height: 280))
        let source = TransferRows()
        table.addTableColumn(NSTableColumn(identifier: .init("rows")))
        table.dataSource = source; table.allowsMultipleSelection = true; table.reloadData()
        let button = NSButton(title: "Trash", target: nil, action: nil)
        panel.contentView?.addSubview(table); panel.contentView?.addSubview(button)
        panel.selectionTable = table
        panel.makeFirstResponder(button)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0))
        #expect(panel.performKeyEquivalent(with: event))
        #expect(table.selectedRowIndexes == IndexSet(0..<3))
        #expect(panel.firstResponder === table)
        table.deselectAll(nil)
        let plain = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        _ = panel.performKeyEquivalent(with: plain)
        #expect(table.selectedRowIndexes.isEmpty)
    }

    @Test func trashPanelShowsTotalsRemovalTimeAndRestoreControls() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-trash-ui-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let batch = try store.begin(names: ["report.txt", "missing.txt"])
        let receive = try store.receive(batch: batch.id, name: "report.txt")
        try store.accept(receive, bytes: 4)
        try Data("test".utf8).write(to: receive.staging.appendingPathComponent("report.txt"))
        _ = try store.complete(receive, name: "report.txt")
        try store.finishWaiting(batch.id, reason: "Client cancelled")
        try store.remove(batch.id)
        let panel = TransferPanel(store: store, showingTrash: true)
        defer { panel.window.close() }
        panel.window.contentView?.layoutSubtreeIfNeeded()
        let views = descendants(try #require(panel.window.contentView))
        let labels = views.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains("2 items in 1 transfer · 4 bytes total data"))
        let table = try #require(panel.window.selectionTable)
        let row = try #require(panel.tableView(table, viewFor: nil, row: 0))
        let rowLabels = descendants(row).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(rowLabels.contains { $0.contains("Removed ") && $0.contains("Client cancelled") })
        let buttons = views.compactMap { $0 as? NSButton }
        #expect(buttons.contains { $0.title == "Restore" })
        #expect(buttons.contains { $0.title == "Delete Permanently…" })
        #expect(!buttons.contains { $0.title == "Save a Copy…" })
        table.selectAll(nil)
        let restore = try #require(buttons.first { $0.title == "Restore" })
        restore.performClick(nil)
        #expect(try store.snapshot().first?.id == batch.id)
        #expect(table.numberOfRows == 0)
        let refreshedLabels = descendants(try #require(panel.window.contentView)).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(refreshedLabels.contains("0 items in 0 transfers · 0 bytes total data"))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor
private final class TransferRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
}
