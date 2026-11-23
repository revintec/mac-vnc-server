import CoreFoundation
import CVNCSession
import Darwin
import Foundation
import Testing

struct ConsoleCaptureServiceTests {
    private let label = "com.mac-vnc-server.console-capture.mac-vnc-console.Abc123"

    private func job() throws -> [String: Any] {
        let value = try #require(VNCConsoleCaptureJobCreate(label, "/test/mac-vnc-server", 123, 456))
        return value as NSDictionary as! [String: Any]
    }

    private func accepts(_ value: [String: Any], expectedLabel: String? = nil) -> Bool {
        var audit: Int32 = 0, owner: Int32 = 0
        let result = VNCConsoleCaptureJobReadOwner(value as CFDictionary, expectedLabel ?? label, &audit, &owner)
        return result == 0 && audit == 123 && owner == 456
    }

    @Test func launchdUsesAuditAttachmentHelperAndRetainsOwnership() throws {
        let value = try job()
        #expect(value["ProgramArguments"] as? [String] == ["/test/mac-vnc-server", "--console-capture-service", "123", "456"])
        #expect(value["Program"] == nil)
        #expect(accepts(value))
        #expect(!accepts(value, expectedLabel: "unrelated-job"))
    }

    @Test func directLaunchJobsRemainRecognizableOnlyWithTheirOriginalSchema() throws {
        var old = try job()
        var fields = try #require(old["MacVNCServerOwnership"] as? [String: Any])
        fields["Version"] = 2
        old["MacVNCServerOwnership"] = fields
        #expect(!accepts(old))
        old["ProgramArguments"] = ["/usr/libexec/replayd"]
        #expect(accepts(old))
        fields["Version"] = 3
        old["MacVNCServerOwnership"] = fields
        #expect(!accepts(old))
    }

    @Test func oldHelperJobsRemainRecognizableForOrphanCleanup() throws {
        var old = try job()
        old.removeValue(forKey: "MacVNCServerOwnership")
        old["ProgramArguments"] = ["/test/mac-vnc-server", "--console-capture-service", "123", "456"]
        #expect(accepts(old))
        old["ProgramArguments"] = ["/test/mac-vnc-server", "--some-other-helper", "123", "456"]
        #expect(!accepts(old))
    }

    @Test func alteredLaunchCommandsAndExtraKeysNeverProveOwnership() throws {
        for (key, value) in [("ProgramArguments", ["/bin/sleep", "60"] as Any),
                             ("Program", "/bin/sleep" as Any),
                             ("MachServices", ["unrelated-service": true] as Any),
                             ("RunAtLoad", false as Any),
                             ("unexpected", true as Any)] {
            var changed = try job()
            changed[key] = value
            #expect(!accepts(changed))
        }
    }

    @Test func malformedOwnershipCannotTriggerCleanup() throws {
        let original = try job()
        let fields = try #require(original["MacVNCServerOwnership"] as? [String: Any])
        for (key, values) in [
            ("Version", [1, 2, 4, "3"] as [Any]),
            ("OwnerPID", ["1", "0", "-1", "456x", "2147483648", 456] as [Any]),
            ("AuditSession", ["0", "-1", "123x", "2147483648", 123] as [Any]),
            ("Executable", ["relative-path", 123] as [Any])
        ] {
            for value in values {
                var invalid = fields
                invalid[key] = value
                var changed = original
                changed["MacVNCServerOwnership"] = invalid
                #expect(!accepts(changed))
            }
        }
        for value in ["invalid" as Any, [] as Any, [:] as [String: Any]] {
            var changed = original
            changed["MacVNCServerOwnership"] = value
            #expect(!accepts(changed))
        }
    }
}
