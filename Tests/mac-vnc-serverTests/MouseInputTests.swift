import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import mac_vnc_server

@Test func allInputStaysInTheUserSessionIncludingDisconnectReleases() {
    var taps: [CGEventTapLocation] = []
    var events: [CGEvent] = []
    let input = MacInputController(postEvent: { tap, event in
        taps.append(tap)
        events.append(event)
    })
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 100, height: 100)
    input.pointer(buttonMask: 1, x: 20, y: 20, layout: layout)
    input.key(down: true, keysym: 0xffe3, mapAltToCommand: false)
    input.key(down: true, keysym: 0x61, mapAltToCommand: false)
    input.key(down: true, keysym: 0x2603, mapAltToCommand: false)
    input.pointer(buttonMask: 9, x: 25, y: 25, layout: layout)
    input.releaseKeys()

    for type: CGEventType in [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                              .keyDown, .keyUp, .flagsChanged, .scrollWheel] {
        #expect(events.contains { $0.type == type })
    }
    #expect(taps.allSatisfy { $0 == .cgSessionEventTap })
    #expect(events.suffix(3).map(\.type) == [.leftMouseUp, .keyUp, .flagsChanged])
}

@Test func mouseEventsCarrySingleDoubleAndTripleClickCounts() throws {
    var now: TimeInterval = 10
    var events: [CGEvent] = []
    let input = MacInputController(eventTime: { now }, doubleClickInterval: { 0.5 },
                                   postEvent: { _, event in events.append(event) })
    let layout = VirtualDisplayLayout(displays: [], origin: CGPoint(x: -100, y: 50),
                                      scale: 2, width: 400, height: 300)
    for _ in 0..<3 {
        input.pointer(buttonMask: 1, x: 100, y: 80, layout: layout)
        now += 0.05
        input.pointer(buttonMask: 0, x: 100, y: 80, layout: layout)
        now += 0.1
    }
    let clicks = events.filter { $0.type == .leftMouseDown || $0.type == .leftMouseUp }
    #expect(clicks.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2, 3, 3])
    #expect(clicks.allSatisfy { $0.location == CGPoint(x: -50, y: 90) })
    // Verify AppKit interprets the Quartz metadata as an actual double-click.
    let secondDown = try #require(NSEvent(cgEvent: clicks[2]))
    #expect(secondDown.clickCount == 2)
}

@Test func mouseClickSequenceResetsForTimeoutDragAndDifferentButton() {
    var clicks = MouseClickTracker()
    let point = CGPoint(x: 20, y: 40)
    #expect(clicks.buttonDown(.left, at: point, time: 1, interval: 0.2) == 1)
    #expect(clicks.buttonUp(.left) == 1)
    #expect(clicks.buttonDown(.left, at: point, time: 1.3, interval: 0.2) == 1)
    clicks.moved(to: CGPoint(x: 50, y: 40))
    clicks.moved(to: point)
    #expect(clicks.buttonUp(.left) == 1)
    #expect(clicks.buttonDown(.left, at: point, time: 1.4, interval: 0.2) == 1)
    _ = clicks.buttonUp(.left)
    #expect(clicks.buttonDown(.right, at: point, time: 1.5, interval: 0.2) == 1)
    _ = clicks.buttonUp(.right)
    #expect(clicks.buttonDown(.left, at: point, time: 1.6, interval: 0.2) == 1)
    _ = clicks.buttonUp(.left)
    #expect(clicks.buttonDown(.left, at: CGPoint(x: 21, y: 42), time: 1.7, interval: 0.2) == 2)
    _ = clicks.buttonUp(.left)
    #expect(clicks.buttonDown(.left, at: CGPoint(x: 80, y: 42), time: 1.8, interval: 0.2) == 1)
}

@Test func duplicatePointerPacketsDoNotCreateExtraClicksAndDisconnectReleasesMouse() {
    var events: [CGEvent] = []
    let input = MacInputController(eventTime: { 10 }, doubleClickInterval: { 0.5 },
                                   postEvent: { _, event in events.append(event) })
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 100, height: 100)
    input.pointer(buttonMask: 1, x: 20, y: 20, layout: layout)
    input.pointer(buttonMask: 1, x: 20, y: 20, layout: layout)
    #expect(events.filter { $0.type == .leftMouseDown }.count == 1)
    input.releaseKeys()
    #expect(events.last?.type == .leftMouseUp)
    input.pointer(buttonMask: 1, x: 20, y: 20, layout: layout)
    #expect(events.last(where: { $0.type == .leftMouseDown })?.getIntegerValueField(.mouseEventClickState) == 1)
    input.releaseKeys()
}

@Test func applePointerButtonsBecomeTheCorrectMacMouseEvents() {
    #expect(AppleRFB.standardButtonMask(0x02) == 0x04) // Apple's right button
    #expect(AppleRFB.standardButtonMask(0x04) == 0x02) // Apple's middle button
    #expect(AppleRFB.standardButtonMask(0x19) == 0x19) // left and wheel unchanged
    var events: [CGEvent] = []
    let input = MacInputController(postEvent: { _, event in events.append(event) })
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 100, height: 100)
    input.pointer(buttonMask: AppleRFB.standardButtonMask(2), x: 20, y: 20, layout: layout)
    #expect(events.first?.type == .rightMouseDown)
    #expect(events.last?.type == .rightMouseDragged)
    input.pointer(buttonMask: 0, x: 20, y: 20, layout: layout)
    #expect(events.last?.type == .rightMouseUp)
    input.pointer(buttonMask: AppleRFB.standardButtonMask(4), x: 20, y: 20, layout: layout)
    #expect(events.last?.type == .otherMouseDown)
    #expect(events.last?.getIntegerValueField(.mouseEventButtonNumber) == Int64(CGMouseButton.center.rawValue))
    input.releaseKeys()
}
