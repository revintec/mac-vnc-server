import Foundation

enum CLIError: LocalizedError {
    case helpRequested(String)
    case invalidArgument(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .invalidArgument(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}

enum CLICommand {
    case run(ServerConfig)
    case service(ServerConfig, [String])
    case serviceRestart
    case permissions
    case diagnose
    case wakeup
    case update
    case version
    case transfers(TransferStore.Options)

    func run(transferInbox: TransferInbox? = nil) async throws {
        switch self {
        case .run(let config):
            let resolvedConfig = try resolvePassword(in: config)
            try await runServers(config: resolvedConfig, transferInbox: transferInbox)
        case .service(let config, let arguments):
            _ = try resolvePassword(in: config)
            try LaunchAgentService.install(arguments: arguments)
        case .serviceRestart:
            try LaunchAgentService.restart()
        case .permissions:
            Permissions.printAndRequest()
        case .diagnose:
            Permissions.printStatus()
            MacScreenCapture.printDisplayDiagnostics()
        case .wakeup:
            try DisplayWakeup.run()
        case .update:
            try await BinaryUpdater.run()
        case .transfers:
            break // The main-thread AppKit loop owns the receiving panel.
        case .version:
            print("mac-vnc-server \(AppVersion.current)")
        }
    }

    private func resolvePassword(in config: ServerConfig) throws -> ServerConfig {
        guard config.passwordFromConfig else {
            return config
        }

        let password = try PasswordStore.loadOrCreate()
        print("VNC password: \(password)")
        return config.withResolvedPassword(password)
    }

    private func runServers(config: ServerConfig, transferInbox: TransferInbox?) async throws {
        let inputs = SharedInputController(input: MacInputController(logger: ServerLogger(verbose: config.verbose)))
        let configs = try await expandedConfigs(from: config)
        let sharedLogger = ServerLogger(verbose: config.verbose)
        let sharedCapture = try await StreamingScreenCapture(
            scale: config.scale,
            fps: config.fps,
            displaySelection: configs.count == 1 ? configs[0].displaySelection : .all,
            logger: sharedLogger,
            cursorMode: config.cursorMode
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for config in configs {
                    let capture: any FramebufferSource & Sendable
                    if configs.count == 1 {
                        capture = sharedCapture
                    } else {
                        switch config.displaySelection {
                        case .all:
                            capture = SelectedDisplayFramebufferSource(source: sharedCapture, displayIndex: nil)
                        case .display(let index):
                            capture = SelectedDisplayFramebufferSource(source: sharedCapture, displayIndex: index)
                        case .automatic:
                            throw CLIError.invalidArgument("automatic display selection could not be expanded")
                        }
                    }
                    group.addTask {
                        try await Self.runServer(config: config, inputs: inputs, capture: capture, transferInbox: transferInbox)
                    }
                }
                // Propagate a failed listener immediately so sibling listeners
                // are cancelled and the shared capture is stopped as well.
                for try await _ in group {}
            }
        } catch {
            await sharedCapture.stop()
            throw error
        }
        await sharedCapture.stop()
    }

    private func expandedConfigs(from config: ServerConfig) async throws -> [ServerConfig] {
        guard config.displaySelection == .automatic else {
            return [config]
        }

        let displayCount = try await StreamingScreenCapture.displayCount()
        guard displayCount > 0 else {
            throw RFBError.captureFailed("ScreenCaptureKit found no displays")
        }
        guard Int(config.port) + displayCount <= Int(UInt16.max) else {
            throw CLIError.invalidArgument("not enough consecutive ports starting at \(config.port) for \(displayCount) display(s)")
        }

        var configs = [config.with(displaySelection: .all)]
        for displayIndex in 1...displayCount {
            configs.append(config.with(port: config.port + UInt16(displayIndex), displaySelection: .display(displayIndex)))
        }
        return configs
    }

    private static func runServer(config: ServerConfig, inputs: SharedInputController, capture: FramebufferSource, transferInbox: TransferInbox?) async throws {
        let logger = ServerLogger(verbose: config.verbose)
        let server = RFBServer(
            config: config,
            capture: capture,
            makeInput: { inputs.makeClient() },
            makeClipboard: { MacClipboard() },
            logger: logger, transferInbox: transferInbox
        )
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try server.run()
            try Task.checkCancellation()
        } onCancel: { server.stop() }
    }
}

enum CLI {
    private struct ParsedRun {
        let config: ServerConfig
        let registerService: Bool
        let serviceArguments: [String]
    }

    static func parse(arguments: [String]) throws -> CLICommand {
        guard let subcommand = arguments.first else {
            return command(for: try parseRun(arguments))
        }

        if subcommand == "--service-restart" {
            guard arguments.count == 1 else {
                throw CLIError.invalidArgument("--service-restart does not accept server options")
            }
            return .serviceRestart
        }

        if subcommand.hasPrefix("-") {
            return command(for: try parseRun(arguments))
        }

        switch subcommand {
        case "transfers":
            return .transfers(try parseRun(Array(arguments.dropFirst())).config.transferOptions)
        case "run":
            return command(for: try parseRun(Array(arguments.dropFirst())))
        case "permissions":
            return .permissions
        case "diagnose":
            return .diagnose
        case "wakeup":
            return .wakeup
        case "update":
            return .update
        case "version", "--version", "-V":
            return .version
        case "-h", "--help", "help":
            throw CLIError.helpRequested(helpText)
        default:
            throw CLIError.invalidArgument("unknown command '\(subcommand)'\n\n\(helpText)")
        }
    }

    private static func command(for parsedRun: ParsedRun) -> CLICommand {
        if parsedRun.registerService {
            return .service(parsedRun.config, parsedRun.serviceArguments)
        }
        return .run(parsedRun.config)
    }

    private static func parseRun(_ arguments: [String]) throws -> ParsedRun {
        var port: UInt16 = 5900
        var bindAddress = "127.0.0.1"
        var password: String?
        var passwordFromConfig = true
        var insecureAllowNoAuth = false
        var fps = 60
        var scale: Double = 1
        var encodingPreference = EncodingPreference.auto
        var zlibConfiguration = ZlibConfiguration()
        var displaySelection = DisplaySelection.automatic
        var verbose = false
        var clipboardSync = false
        var fileTransfer = false
        var cursorMode = CursorMode.auto
        var allowEncryption = true
        var adaptiveStreaming = true
        var adaptiveFrameRate = true
        var transferOptions = TransferStore.Options()
        var nativeFileDrops = false
        var registerService = false
        var serviceFlagIndices = Set<Int>()
        var index = 0

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--port", "-p":
                index += 1
                guard index < arguments.count, let parsed = UInt16(arguments[index]) else {
                    throw CLIError.invalidArgument("--port requires a valid TCP port")
                }
                port = parsed
            case "--bind":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--bind requires an IPv4 address")
                }
                bindAddress = arguments[index]
            case "--password":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--password requires a value")
                }
                password = arguments[index]
                passwordFromConfig = false
            case "--no-password":
                password = nil
                passwordFromConfig = false
            case "--insecure-allow-no-auth":
                insecureAllowNoAuth = true
            case "--fps":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--fps requires auto or a value between 1 and 120")
                }
                if arguments[index] == "auto" {
                    fps = 60
                    adaptiveFrameRate = true
                } else if let parsed = Int(arguments[index]), (1...120).contains(parsed) {
                    fps = parsed
                    adaptiveFrameRate = false
                } else {
                    throw CLIError.invalidArgument("--fps requires auto or a value between 1 and 120")
                }
            case "--scale":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0, parsed <= 4 else {
                    throw CLIError.invalidArgument("--scale requires a value greater than 0 and at most 4")
                }
                scale = parsed
            case "--encoding":
                index += 1
                guard index < arguments.count, let parsed = EncodingPreference(rawValue: arguments[index]) else {
                    throw CLIError.invalidArgument("--encoding must be auto, zrle, zlib, or raw")
                }
                encodingPreference = parsed
            case "--zlib-backend":
                index += 1
                guard index < arguments.count, let backend = ZlibBackend(rawValue: arguments[index]) else {
                    throw CLIError.invalidArgument("--zlib-backend must be zlib-ng or system")
                }
                zlibConfiguration.backend = backend
            case "--zlib-level":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--zlib-level requires auto or 0...9")
                }
                if arguments[index] == "auto" {
                    zlibConfiguration.level = nil
                } else if let level = Int32(arguments[index]), (0...9).contains(level) {
                    zlibConfiguration.level = level
                } else {
                    throw CLIError.invalidArgument("--zlib-level requires auto or 0...9")
                }
            case "--display":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--display requires all or a 1-based display number")
                }
                if arguments[index] == "all" {
                    displaySelection = .all
                } else if let parsed = Int(arguments[index]), parsed > 0 {
                    displaySelection = .display(parsed)
                } else {
                    throw CLIError.invalidArgument("--display requires all or a 1-based display number")
                }
            case "--cursor":
                index += 1
                guard index < arguments.count, let parsed = CursorMode(rawValue: arguments[index]) else {
                    throw CLIError.invalidArgument("--cursor must be auto or embedded")
                }
                cursorMode = parsed
            case "--verbose":
                verbose = true
            case "--service":
                registerService = true
                serviceFlagIndices.insert(index)
            case "--file-transfer":
                fileTransfer = true
            case "--file-drop-mode":
                index += 1
                guard index < arguments.count, ["staged", "native"].contains(arguments[index]) else {
                    throw CLIError.invalidArgument("--file-drop-mode must be staged or native")
                }
                nativeFileDrops = arguments[index] == "native"
            case "--transfer-directory":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw CLIError.invalidArgument("--transfer-directory requires an absolute path")
                }
                transferOptions.root = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--transfer-limit-gib", "--transfer-free-gib":
                index += 1
                guard index < arguments.count, let value = Int64(arguments[index]), (1...1_048_576).contains(value) else {
                    throw CLIError.invalidArgument("\(arg) requires a positive integer GiB value")
                }
                if arg == "--transfer-limit-gib" { transferOptions.maximumBytes = value * 1_024 * 1_024 * 1_024 }
                else { transferOptions.minimumFreeBytes = value * 1_024 * 1_024 * 1_024 }
            case "--no-encryption":
                allowEncryption = false
            case "--clipboard-sync":
                clipboardSync = true
            case "--no-adaptive":
                adaptiveStreaming = false
                adaptiveFrameRate = false
            case "--help", "-h":
                throw CLIError.helpRequested(helpText)
            default:
                throw CLIError.invalidArgument("unknown run argument '\(arg)'")
            }
            index += 1
        }

        if !isLoopback(bindAddress), !passwordFromConfig, password == nil, !insecureAllowNoAuth {
            throw CLIError.invalidArgument("""
            refusing to expose unauthenticated VNC on \(bindAddress)
            Use --password for LAN, or pass --insecure-allow-no-auth if you explicitly want no auth.
            """)
        }

        let config = ServerConfig(
            bindAddress: bindAddress,
            port: port,
            password: password,
            passwordFromConfig: passwordFromConfig,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference,
            displaySelection: displaySelection,
            verbose: verbose,
            clipboardSync: clipboardSync,
            adaptiveStreaming: adaptiveStreaming,
            adaptiveFrameRate: adaptiveFrameRate,
            fileTransfer: fileTransfer,
            cursorMode: cursorMode,
            allowEncryption: allowEncryption,
            zlibConfiguration: zlibConfiguration,
            transferOptions: transferOptions, nativeFileDrops: nativeFileDrops
        )
        return ParsedRun(
            config: config,
            registerService: registerService,
            serviceArguments: arguments.enumerated()
                .filter { !serviceFlagIndices.contains($0.offset) }
                .map(\.element)
        )
    }

    private static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address.hasPrefix("127.")
    }

    static func errorMessage(for error: Error) -> String {
        var message = error.localizedDescription
        if case RFBError.captureFailed(let captureMessage) = error,
           captureMessage == "ScreenCaptureKit found no displays" {
            message += "\nHint: run 'mac-vnc-server wakeup' to wake the display, then start the server again."
        }
        return message
    }

    static let helpText = """
    mac-vnc-server \(AppVersion.current)

    Usage:
      mac-vnc-server run [--service] [--bind 127.0.0.1] [--port 5900] [--password value]
                          [--fps auto|1...120] [--scale 1.0] [--encoding auto|zrle|zlib|raw]
                          [--display all|number] [--verbose] [--clipboard-sync] [--file-transfer] [--no-adaptive]
                          [--cursor auto|embedded] [--no-encryption]
                          [--zlib-backend zlib-ng|system] [--zlib-level auto|0...9]
      mac-vnc-server --service-restart
      mac-vnc-server permissions
      mac-vnc-server diagnose
      mac-vnc-server wakeup
      mac-vnc-server update
      mac-vnc-server version
      mac-vnc-server transfers [--transfer-directory /absolute/path]

    Default bind address is 127.0.0.1 and default port is 5900. The first run generates an 8-character password in ~/.mac-vnc-server/config.json and prints it to stdout.
    Without --display, port 5900 serves all displays and 5901, 5902, ... serve each display.
    Use --display all to keep only the single combined-display server, or --display 1 for one display.
    Use --verbose to enable periodic framebuffer update logs.
    Zlib encoding defaults to zlib-ng with adaptive levels 2/3; system uses levels 1/3.
    Use --zlib-level 0...9 to fix the Zlib level (0 sends stored blocks); auto allows adaptation.
    Cursor defaults to client rendering when available; --cursor embedded includes it in captured frames.
    Use --no-encryption to require plaintext session traffic; password authentication is retained.
    With --file-transfer, --no-encryption enables experimental plaintext operation on a plain VNC URL.
    It suppresses the viewer's encryption key exchange; encrypted traffic is refused.
    Use --clipboard-sync for text and images with Apple Screen Sharing (text with classic VNC).
    Use --file-transfer for file/folder drag and drop with vnc://HOST:PORT/.
    Incoming files are staged in ~/Library/Application Support/mac-vnc-server/Transfers.
    Keep holding to continue with local files when ready, or drag completed rows from Received Files.
    Use --file-drop-mode native to retain the original Finder/promise destination workflow.
    Storage: --transfer-directory /absolute/path, --transfer-limit-gib 10, --transfer-free-gib 1.
    The transfers command reopens received files without starting a server.
    Otherwise file transfer uses Apple authentication: any username and the configured server password.
    Use --no-adaptive to disable adaptive FPS, compression, and scale changes.
    Use --service to install and start a per-user LaunchAgent that runs in the UI session.
    Use --service-restart to restart the registered LaunchAgent.
    Use --no-password only for clients that accept unauthenticated VNC.
    """
}

enum DisplayWakeup {
    static func run() throws {
        try signal()
        print("Sent display wake signal with caffeinate.")
    }

    static func signal() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "5"]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed("caffeinate failed with exit status \(process.terminationStatus)")
        }
    }
}

private extension ServerConfig {
    func with(port: UInt16? = nil, displaySelection: DisplaySelection) -> ServerConfig {
        ServerConfig(
            bindAddress: bindAddress,
            port: port ?? self.port,
            password: password,
            passwordFromConfig: passwordFromConfig,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference,
            displaySelection: displaySelection,
            verbose: verbose,
            clipboardSync: clipboardSync,
            adaptiveStreaming: adaptiveStreaming,
            adaptiveFrameRate: adaptiveFrameRate,
            fileTransfer: fileTransfer,
            cursorMode: cursorMode,
            allowEncryption: allowEncryption,
            zlibConfiguration: zlibConfiguration,
            transferOptions: transferOptions, nativeFileDrops: nativeFileDrops
        )
    }

    func withResolvedPassword(_ password: String) -> ServerConfig {
        ServerConfig(
            bindAddress: bindAddress,
            port: port,
            password: password,
            passwordFromConfig: false,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference,
            displaySelection: displaySelection,
            verbose: verbose,
            clipboardSync: clipboardSync,
            adaptiveStreaming: adaptiveStreaming,
            adaptiveFrameRate: adaptiveFrameRate,
            fileTransfer: fileTransfer,
            cursorMode: cursorMode,
            allowEncryption: allowEncryption,
            zlibConfiguration: zlibConfiguration,
            transferOptions: transferOptions, nativeFileDrops: nativeFileDrops
        )
    }
}
