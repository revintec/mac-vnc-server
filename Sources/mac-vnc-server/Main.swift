import AppKit
import Foundation
import Darwin
import CVNCSession

@main
struct MacVNCServerApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--console-capture-broker", "--console-capture-service"].contains(arguments.first ?? "") {
            // The broker owns synchronous launchd cleanup and signal handling.
            // The service stage prepares credentials, then execs Apple's daemon.
            // Both must run before AppKit or our normal shutdown controller.
            do {
                let result: Int32
                switch try CLI.parse(arguments: arguments) {
                case .consoleCaptureBroker(let audit):
                    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                    result = VNCConsoleRunCaptureBroker(VNCConsoleIdentity(uid: 0, audit_id: audit), executable)
                case .consoleCaptureService(let audit, let manager):
                    result = VNCConsoleExecCaptureService(VNCConsoleIdentity(uid: 0, audit_id: audit), manager)
                default: throw CLIError.invalidArgument("invalid console capture helper")
                }
                if result != 0 { fputs("Console capture helper failed: \(String(cString: strerror(result))) (\(result))\n", stderr) }
                Foundation.exit(result == 0 ? 0 : 1)
            } catch {
                fputs("mac-vnc-server: \(CLI.errorMessage(for: error))\n", stderr)
                Foundation.exit(1)
            }
        }
        let shutdown = ProcessShutdown.shared
        shutdown.installSignalHandlers()
        do {
            let command = try CLI.parse(arguments: arguments).resolvingPassword()
            // Set credentials/audit membership, then exec before AppKit can
            // initialize. The attached entry point verifies the fresh process.
            if case .consoleWorker(let options, let attached) = command {
                setvbuf(stdout, nil, _IOLBF, 0)
                if attached { try options.verifyAttachment() }
                else { try options.attachAndExec() }
            }
            var panel: TransferPanel?
            var inbox: TransferInbox?
            let storageOptions: TransferStore.Options?
            var verbose = false
            let panelOnly: Bool
            switch command {
            case .run(let config):
                verbose = config.verbose
                if config.sessionTarget == .console { setvbuf(stdout, nil, _IOLBF, 0) }
                storageOptions = config.sessionTarget == .user && config.fileTransfer && !config.nativeFileDrops ? config.transferOptions : nil
                panelOnly = false
            case .transfers(let options): storageOptions = options; panelOnly = true
            default: storageOptions = nil; panelOnly = false
            }
            if let storageOptions {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
                let store = try TransferStore(options: storageOptions)
                panel = TransferPanel(store: store, logger: ServerLogger(verbose: verbose))
                inbox = panel?.makeInbox()
            }
            let transferInbox = inbox
            // Keep the AppKit loop alive while cancellation closes listeners and
            // stops capture. Exiting first can leave replayd state for this path.
            let runner: Task<Void, Never>? = panelOnly ? nil : Task.detached {
                do { try await command.run(transferInbox: transferInbox); Foundation.exit(0) }
                catch is CancellationError { Foundation.exit(0) }
                catch {
                    fputs("mac-vnc-server: \(CLI.errorMessage(for: error))\n", stderr)
                    Foundation.exit(1)
                }
            }
            if let runner { shutdown.attach(runner) }
            withExtendedLifetime(shutdown) {
                if let panel {
                    if panelOnly { panel.show() }
                    withExtendedLifetime(panel) { NSApp.run() }
                } else { dispatchMain() }
            }
        } catch CLIError.helpRequested(let text) {
            print(text)
        } catch {
            fputs("mac-vnc-server: \(CLI.errorMessage(for: error))\n", stderr)
            Foundation.exit(1)
        }
    }
}
