import AppKit
import Foundation
import Darwin
import CVNCSession

@main
struct MacVNCServerApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--console-capture-service" {
            // Prepare credentials, then exec Apple's daemon before AppKit or
            // the normal shutdown controller initializes.
            do {
                let result: Int32
                switch try CLI.parse(arguments: arguments) {
                case .consoleCaptureService(let audit, let owner):
                    result = VNCConsoleExecCaptureService(VNCConsoleIdentity(uid: 0, audit_id: audit), owner)
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
            if case .sessionWorker(let options, let attached) = command {
                setvbuf(stdout, nil, _IOLBF, 0)
                if attached { try options.verifyAttachment() }
                else { try options.attachAndExec() }
                shutdown.installSignalHandlers([SIGHUP])
            }
            var panel: TransferPanel?
            var inbox: TransferInbox?
            let storageOptions: TransferStore.Options?
            var verbose = false
            var showsStatus = false
            let panelOnly: Bool
            switch command {
            case .run(let config):
                verbose = config.verbose
                showsStatus = config.sessionTarget == .user
                if config.sessionTarget == .console || config.sessionTarget == .listener {
                    setvbuf(stdout, nil, _IOLBF, 0)
                    shutdown.installSignalHandlers([SIGHUP])
                }
                storageOptions = config.sessionTarget == .user && config.fileTransfer && !config.nativeFileDrops ? config.transferOptions : nil
                panelOnly = false
            case .sessionWorker(let options, _):
                verbose = options.config.verbose
                showsStatus = options.identity.uid != 0
                var storage = options.config.transferOptions
                if !options.config.transferDirectoryIsExplicit { storage.root = TransferStore.Options().root }
                storageOptions = showsStatus && options.config.fileTransfer && !options.config.nativeFileDrops ? storage : nil
                panelOnly = false
            case .transfers(let options): storageOptions = options; panelOnly = true; showsStatus = true
            default: storageOptions = nil; panelOnly = false
            }
            if showsStatus {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
            }
            if let storageOptions {
                let store = try TransferStore(options: storageOptions)
                panel = TransferPanel(store: store, logger: ServerLogger(verbose: verbose))
                inbox = panel?.makeInbox()
            }
            let remoteStatus = showsStatus ? RemoteSessionStatus(showFiles: panel.map { panel in { panel.show() } },
                                                               logger: ServerLogger(verbose: verbose)) : nil
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
                if showsStatus {
                    if panelOnly { panel?.show() }
                    withExtendedLifetime((panel, remoteStatus)) { NSApp.run() }
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
