import AppKit
import Foundation
import Darwin

@main
struct MacVNCServerApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let command = try CLI.parse(arguments: Array(CommandLine.arguments.dropFirst())).resolvingPassword()
            var panel: TransferPanel?
            var inbox: TransferInbox?
            let storageOptions: TransferStore.Options?
            var verbose = false
            let panelOnly: Bool
            switch command {
            case .run(let config):
                verbose = config.verbose
                storageOptions = config.fileTransfer && !config.nativeFileDrops ? config.transferOptions : nil
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
            for number in [SIGINT, SIGTERM] { signal(number, SIG_IGN) }
            let runner: Task<Void, Never>? = panelOnly ? nil : Task.detached {
                do { try await command.run(transferInbox: transferInbox); Foundation.exit(0) }
                catch is CancellationError { Foundation.exit(0) }
                catch {
                    fputs("mac-vnc-server: \(CLI.errorMessage(for: error))\n", stderr)
                    Foundation.exit(1)
                }
            }
            let signals = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    if let runner { runner.cancel() } else { Foundation.exit(0) }
                }
                source.resume()
                return source
            }
            withExtendedLifetime(signals) {
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
