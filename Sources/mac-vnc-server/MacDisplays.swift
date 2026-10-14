import ApplicationServices
import CoreGraphics
import Foundation

enum MacDisplays {
    static func printDisplayDiagnostics() {
        do {
            let displayIDs = try activeDisplayIDs()
            print("Displays: \(displayIDs.count)")
            for (index, displayID) in displayIDs.enumerated() {
                let bounds = CGDisplayBounds(displayID)
                let width = CGDisplayPixelsWide(displayID)
                let height = CGDisplayPixelsHigh(displayID)
                print("- display=\(index + 1) id=\(displayID) bounds=\(bounds) pixels=\(width)x\(height)")
            }
        } catch {
            print("Displays: unavailable (\(error.localizedDescription))")
        }
    }

    static func activeDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &count)
        guard result == .success else {
            throw RFBError.captureFailed("CGGetActiveDisplayList failed: \(result.rawValue)")
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        result = CGGetActiveDisplayList(count, &displays, &count)
        guard result == .success else {
            throw RFBError.captureFailed("CGGetActiveDisplayList failed: \(result.rawValue)")
        }

        return Array(displays.prefix(Int(count)))
    }
}
