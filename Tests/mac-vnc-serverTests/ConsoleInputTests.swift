import CoreGraphics
import CVNCSession
import Darwin
import Testing
@testable import mac_vnc_server

struct ConsoleInputTests {
    @Test func normalUserAndUnverifiedRootCannotOpenPhysicalInput() {
        var error: Int32 = 0
        #expect(VNCConsoleInputCreate(VNCConsoleIdentity(uid: 501, audit_id: 1), &error) == nil)
        #expect(error == EPERM)
        #expect(VNCConsoleInputCreate(VNCConsoleIdentity(uid: 0, audit_id: 1), &error) == nil)
        #expect(error != 0)
    }

    @Test func existingKeyMappingPreservesShiftAndUnicodeWithoutGlobalFlags() throws {
        var events: [VNCConsoleInputEvent] = []
        let input = MacInputController(postEvent: { _, event in
            var encoded = VNCConsoleInputEvent()
            #expect(VNCConsoleEncodeInput(event, &encoded) == 0)
            events.append(encoded)
        })
        input.key(down: true, keysym: 65, mapAltToCommand: false)
        input.key(down: false, keysym: 65, mapAltToCommand: false)
        let press = try #require(events.first { $0.type == 10 })
        #expect(press.data.key.keyCode == 0)
        #expect(press.data.key.charCode == 65)
        #expect(press.flags & UInt32(CGEventFlags.maskShift.rawValue) != 0)
        #expect(events.allSatisfy { $0.options == 0 })
        #expect(events.last?.type == 12) // Synthetic Shift release follows key-up.
        #expect(events.last!.flags & UInt32(CGEventFlags.maskShift.rawValue) == 0)

        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        var text: [UniChar] = [0x00e9]
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &text)
        var encoded = VNCConsoleInputEvent()
        #expect(VNCConsoleEncodeInput(event, &encoded) == 0)
        #expect(encoded.data.key.charCode == 0x00e9)
        text = [0xd83d, 0xde00]
        event.keyboardSetUnicodeString(stringLength: 2, unicodeString: &text)
        #expect(VNCConsoleEncodeInput(event, &encoded) == ENOTSUP)
    }

    @Test func pointerCoordinatesClicksAndPixelScrollSurviveConversion() throws {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
            mouseCursorPosition: CGPoint(x: -120, y: 700), mouseButton: .center))
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        event.flags = .maskCommand
        var encoded = VNCConsoleInputEvent()
        #expect(VNCConsoleEncodeInput(event, &encoded) == 0)
        #expect(encoded.location.x == -120 && encoded.location.y == 700)
        #expect(encoded.data.mouse.buttonNumber == 2 && encoded.data.mouse.click == 2)
        #expect(encoded.options == 2 && encoded.flags == UInt32(CGEventFlags.maskCommand.rawValue))
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: -60, wheel2: 20, wheel3: 0))
        #expect(VNCConsoleEncodeInput(scroll, &encoded) == 0)
        #expect(encoded.data.scrollWheel.pointDeltaAxis1 == -60)
        #expect(encoded.data.scrollWheel.pointDeltaAxis2 == 20)
        #expect(encoded.options == 0)
    }
}
