import CoreGraphics
import Foundation

/// RFB sends button transitions, while AppKit expects an explicit click count.
struct MouseClickTracker {
    private struct Sequence {
        let button: CGMouseButton
        let point: CGPoint
        let time: TimeInterval
        let count: Int64
        var released = false
        var movedAway = false
    }

    private var sequence: Sequence?
    private var pressedCounts: [UInt32: Int64] = [:]
    // Coordinates have already been mapped to desktop points, including Retina scaling.
    private let movementTolerance: CGFloat = 4

    mutating func moved(to point: CGPoint) {
        if let current = sequence, !near(point, current.point) {
            sequence?.movedAway = true
        }
    }

    mutating func buttonDown(
        _ button: CGMouseButton,
        at point: CGPoint,
        time: TimeInterval,
        interval: TimeInterval
    ) -> Int64 {
        let count: Int64
        if let previous = sequence, previous.button == button,
           previous.released, !previous.movedAway, near(point, previous.point),
           time >= previous.time, time - previous.time <= interval {
            count = previous.count < Int64.max ? previous.count + 1 : 1
        } else {
            count = 1
        }
        sequence = Sequence(button: button, point: point, time: time, count: count)
        pressedCounts[button.rawValue] = count
        return count
    }

    mutating func buttonUp(_ button: CGMouseButton) -> Int64 {
        if sequence?.button == button { sequence?.released = true }
        return pressedCounts.removeValue(forKey: button.rawValue) ?? 1
    }

    mutating func reset() {
        sequence = nil
        pressedCounts.removeAll()
    }

    private func near(_ first: CGPoint, _ second: CGPoint) -> Bool {
        abs(first.x - second.x) <= movementTolerance && abs(first.y - second.y) <= movementTolerance
    }
}
