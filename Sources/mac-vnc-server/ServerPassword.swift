import Foundation

enum ServerPassword {
    static func read(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        guard let password = environment["VNC_PASSWORD"], !password.isEmpty else {
            throw CLIError.invalidArgument("VNC_PASSWORD must be set to a nonempty value; no password is generated or loaded from disk")
        }
        return password
    }
}
