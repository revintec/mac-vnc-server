import CoreGraphics
import Foundation
import Testing
@testable import mac_vnc_server

@Test func sharedKeysRemainPressedUntilTheirLastOwnerReleases() {
    let events = InputRecorder()
    let shared = SharedInputController(input: events)
    let first = shared.makeClient()
    let second = shared.makeClient()
    first.key(down: true, keysym: 0xffe9, mapAltToCommand: true) // Apple Command
    second.key(down: true, keysym: 0xffe7, mapAltToCommand: false) // classic Command
    first.key(down: true, keysym: 0x61, mapAltToCommand: false)
    second.key(down: true, keysym: 0x61, mapAltToCommand: false)
    #expect(events.keys.map(\.down) == [true, true])
    first.releaseKeys()
    #expect(events.keys.map(\.down) == [true, true])
    #expect(events.releases == 0)
    second.key(down: false, keysym: 0x61, mapAltToCommand: false)
    second.key(down: false, keysym: 0xffe7, mapAltToCommand: false)
    #expect(events.keys.map(\.down) == [true, true, false, false])
    #expect(events.keys.last?.keysym == 0xffe9)
    #expect(events.keys.last?.apple == true)
    second.releaseKeys()
    #expect(events.releases == 1)
}

@Test func disconnectReleasesOnlyThatClientsKeysAndPreservesKeyRepeats() {
    let events = InputRecorder()
    let shared = SharedInputController(input: events)
    let first = shared.makeClient()
    let second = shared.makeClient()
    first.key(down: true, keysym: 0x61, mapAltToCommand: false)
    second.key(down: true, keysym: 0x62, mapAltToCommand: false)
    second.key(down: true, keysym: 0x62, mapAltToCommand: false)
    // A client cannot release a key it does not own.
    first.key(down: false, keysym: 0x62, mapAltToCommand: false)
    first.releaseKeys()
    #expect(events.keys.map(\.keysym) == [0x61, 0x62, 0x62, 0x61])
    #expect(events.keys.map(\.down) == [true, true, true, false])
    #expect(events.releases == 0)
    second.releaseKeys()
    #expect(events.keys.last?.keysym == 0x62)
    #expect(events.keys.last?.down == false)
    #expect(events.releases == 1)
}

@Test func mouseOwnershipSurvivesAnotherClientsMotionAndDisconnect() {
    let events = InputRecorder()
    let shared = SharedInputController(input: events)
    let first = shared.makeClient()
    let second = shared.makeClient()
    let layout = inputTestLayout
    first.pointer(buttonMask: 1, x: 10, y: 10, layout: layout)
    second.pointer(buttonMask: 0, x: 50, y: 60, layout: layout)
    #expect(events.pointers.last?.mask == 1)
    second.pointer(buttonMask: 1, x: 50, y: 60, layout: layout)
    let count = events.pointers.count
    first.releaseKeys()
    #expect(events.pointers.count == count) // second still holds left
    second.releaseKeys()
    #expect(events.pointers.last?.mask == 0)
    #expect(events.pointers.last?.x == 50)
    #expect(events.pointers.last?.y == 60)
}

@Test func releasingOneClientsButtonKeepsOtherButtonsAndDoesNotReplayScroll() {
    let events = InputRecorder()
    let shared = SharedInputController(input: events)
    let first = shared.makeClient()
    let second = shared.makeClient()
    first.pointer(buttonMask: 1, x: 10, y: 10, layout: inputTestLayout)
    second.pointer(buttonMask: 4 | 8, x: 50, y: 60, layout: inputTestLayout)
    #expect(events.pointers.last?.mask == 13)
    first.releaseKeys()
    #expect(events.pointers.last?.mask == 4)
    #expect(events.pointers.last?.x == 50)
    second.releaseKeys()
}

@Test func differentClientsCannotCombineClicksIntoADoubleClick() {
    var now: TimeInterval = 10
    var events: [CGEvent] = []
    let shared = SharedInputController(input: MacInputController(
        eventTime: { now }, doubleClickInterval: { 0.5 }, postMouseEvent: { events.append($0) }))
    let first = shared.makeClient()
    let second = shared.makeClient()
    for client in [first, first, second] {
        client.pointer(buttonMask: 1, x: 20, y: 20, layout: inputTestLayout)
        client.pointer(buttonMask: 0, x: 20, y: 20, layout: inputTestLayout)
        now += 0.1
    }
    #expect(events.filter { $0.type == .leftMouseDown }.map {
        $0.getIntegerValueField(.mouseEventClickState)
    } == [1, 2, 1])
    first.releaseKeys()
    second.releaseKeys()
}

@Test func resettingClickSequenceKeepsReleaseCountForHeldButton() {
    var tracker = MouseClickTracker()
    _ = tracker.buttonDown(.left, at: .zero, time: 1, interval: 0.5)
    _ = tracker.buttonUp(.left)
    #expect(tracker.buttonDown(.left, at: .zero, time: 1.1, interval: 0.5) == 2)
    tracker.resetSequence()
    #expect(tracker.buttonUp(.left) == 2)
    #expect(tracker.buttonDown(.left, at: .zero, time: 1.2, interval: 0.5) == 1)
}

private var inputTestLayout: VirtualDisplayLayout {
    VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 100, height: 100)
}

private final class InputRecorder: InputController {
    struct Key { let down: Bool; let keysym: UInt32; let apple: Bool }
    struct Pointer { let mask: UInt8; let x: UInt16; let y: UInt16 }
    var keys: [Key] = []
    var pointers: [Pointer] = []
    var releases = 0
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
        keys.append(Key(down: down, keysym: keysym, apple: mapAltToCommand))
    }
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        pointers.append(Pointer(mask: buttonMask, x: x, y: y))
    }
    func releaseKeys() { releases += 1 }
}
