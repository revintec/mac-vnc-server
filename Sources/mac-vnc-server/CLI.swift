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
    case consoleWorker(ConsoleWorkerOptions, attached: Bool)
    case consoleCaptureService(Int32, Int32)
    case sessionWorker(SessionWorkerOptions, attached: Bool)

    func run(transferInbox: TransferInbox? = nil) async throws {
        switch self {
        case .run(let config):
            let resolvedConfig = try resolvePassword(in: config)
            if config.sessionTarget == .listener {
                let listener = SessionListener(config: resolvedConfig)
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try listener.run()
                } onCancel: { listener.stop() }
            } else if config.sessionTarget == .console {
                try await ConsoleSessionServer.run(config: resolvedConfig)
            } else {
                try await runServers(config: resolvedConfig, transferInbox: transferInbox)
            }
        case .sessionWorker(let options, let attached):
            guard attached else { throw CLIError.commandFailed("session worker requires exec after attachment") }
            try await AccountSessionWorker.run(options, transferInbox: transferInbox)
        case .consoleWorker(let options, let attached):
            guard attached else { throw CLIError.commandFailed("console worker requires exec after session setup") }
            try await ConsoleWorker.run(options)
        case .consoleCaptureService:
            throw CLIError.commandFailed("console capture helpers must start before AppKit")
        case .service(let config, let arguments):
            try LaunchAgentService.install(arguments: arguments, requiresPasswordEnvironment: config.passwordFromEnvironment)
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
        guard config.passwordFromEnvironment else {
            return config
        }

        return config.withResolvedPassword(try ServerPassword.read())
    }

    func resolvingPassword(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CLICommand {
        if case .run(let config) = self, config.passwordFromEnvironment {
            return .run(config.withResolvedPassword(try ServerPassword.read(environment: environment)))
        }
        return self
    }

    private func runServers(config: ServerConfig, transferInbox: TransferInbox?) async throws {
        // Fail an unavailable interface before starting capture/permission waits.
        _ = try BindAddress.resolve(config.bindAddress)
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
        SessionActivity.shared.attach(server)
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
        if arguments.first == "--session-worker" || arguments.first == "--session-worker-attached" {
            guard arguments.count == 2, let data = arguments[1].data(using: .utf8) else {
                throw CLIError.invalidArgument("invalid session worker arguments")
            }
            let options = try JSONDecoder().decode(SessionWorkerOptions.self, from: data)
            try options.validate()
            return .sessionWorker(options, attached: arguments.first == "--session-worker-attached")
        }
        if arguments.first == "--console-capture-service" {
            guard arguments.count == 3, let audit = Int32(arguments[1]), audit > 0,
                  let owner = Int32(arguments[2]), owner > 1 else {
                throw CLIError.invalidArgument("invalid console capture service arguments")
            }
            return .consoleCaptureService(audit, owner)
        }
        if arguments.first == "--console-worker" || arguments.first == "--console-worker-attached" {
            guard arguments.count == 2, let data = arguments[1].data(using: .utf8) else {
                throw CLIError.invalidArgument("invalid console worker arguments")
            }
            let options = try JSONDecoder().decode(ConsoleWorkerOptions.self, from: data)
            try options.validate()
            return .consoleWorker(options, attached: arguments.first == "--console-worker-attached")
        }
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
        var bindAddress = BindAddress.defaultValue
        let password: String? = nil
        var passwordFromEnvironment = true
        var insecureAllowNoAuth = false
        var fps = 60
        var scale: Double = 1
        var encodingPreference = EncodingPreference.auto
        var zlibConfiguration = ZlibConfiguration()
        var displaySelection = DisplaySelection.automatic
        var verbose = false
        var clipboardSync = true
        var fileTransfer = true
        var cursorMode = CursorMode.auto
        var allowEncryption = false
        var adaptiveStreaming = true
        var adaptiveFrameRate = true
        var transferOptions = TransferStore.Options()
        var nativeFileDrops = false
        var registerService = false
        var sessionTarget = SessionTarget.listener
        var explicitClipboard = false
        var explicitFileTransfer = false
        var serviceFlagIndices = Set<Int>()
        var index = 0

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--session":
                index += 1
                guard index < arguments.count, let target = SessionTarget(rawValue: arguments[index]) else {
                    throw CLIError.invalidArgument("--session must be listener, user, or console")
                }
                sessionTarget = target
            case "--port", "-p":
                index += 1
                guard index < arguments.count, let parsed = UInt16(arguments[index]) else {
                    throw CLIError.invalidArgument("--port requires a valid TCP port")
                }
                port = parsed
            case "--bind":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("-") else {
                    throw CLIError.invalidArgument("--bind requires an IPv4 address or interface name")
                }
                bindAddress = arguments[index]
            case "--password":
                throw CLIError.invalidArgument("--password has been removed; enter macOS credentials in the client. Only legacy --session user/console uses VNC_PASSWORD")
            case "--no-password":
                passwordFromEnvironment = false
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
                explicitFileTransfer = true
            case "--no-file-transfer":
                fileTransfer = false
                explicitFileTransfer = false
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
            case "--encryption":
                allowEncryption = true
            case "--clipboard-sync":
                clipboardSync = true
                explicitClipboard = true
            case "--no-clipboard-sync":
                clipboardSync = false
                explicitClipboard = false
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

        if sessionTarget == .listener {
            guard passwordFromEnvironment, !insecureAllowNoAuth else {
                throw CLIError.invalidArgument("the account listener requires macOS username/password authentication; --no-password is only available with explicit --session user")
            }
            passwordFromEnvironment = false
            if displaySelection == .automatic { displaySelection = .all }
        }

        if sessionTarget == .console {
            guard !registerService else {
                throw CLIError.invalidArgument("--session console runs separately with sudo; --service installs only a user LaunchAgent")
            }
            guard passwordFromEnvironment else {
                throw CLIError.invalidArgument("--session console requires VNC_PASSWORD authentication")
            }
            guard !explicitClipboard, !explicitFileTransfer else {
                throw CLIError.invalidArgument("--session console supports display and input; use the user endpoint for clipboard and file transfer")
            }
            clipboardSync = false
            fileTransfer = false
        }

        if sessionTarget != .listener, !passwordFromEnvironment, password == nil, !insecureAllowNoAuth {
            let resolvedAddress = try BindAddress.resolve(bindAddress)
            if !BindAddress.isLoopback(resolvedAddress) {
                throw CLIError.invalidArgument("""
                refusing to expose unauthenticated VNC on \(bindAddress)
                Set VNC_PASSWORD for authentication, or pass --insecure-allow-no-auth if you explicitly want no auth.
                """)
            }
        }

        let config = ServerConfig(
            bindAddress: bindAddress,
            port: port,
            password: password,
            passwordFromEnvironment: passwordFromEnvironment,
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
            transferOptions: transferOptions, nativeFileDrops: nativeFileDrops,
            insecureAllowNoAuth: insecureAllowNoAuth, sessionTarget: sessionTarget,
            transferDirectoryIsExplicit: arguments.contains("--transfer-directory")
        )
        return ParsedRun(
            config: config,
            registerService: registerService,
            serviceArguments: arguments.enumerated()
                .filter { !serviceFlagIndices.contains($0.offset) }
                .map(\.element)
        )
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
      mac-vnc-server run [--service] [--bind ADDRESS|INTERFACE] [--port 5900]
                          [--session listener|user|console]
                          [--fps auto|1...120] [--scale 1.0] [--encoding auto|zrle|zlib|raw]
                          [--display all|number] [--verbose] [--no-clipboard-sync] [--no-file-transfer] [--no-adaptive]
                          [--cursor auto|embedded] [--encryption|--no-encryption]
                          [--zlib-backend zlib-ng|system] [--zlib-level auto|0...9]
      mac-vnc-server --service-restart
      mac-vnc-server permissions
      mac-vnc-server diagnose
      mac-vnc-server wakeup
      mac-vnc-server update
      mac-vnc-server version
      mac-vnc-server transfers [--transfer-directory /absolute/path]

    Default bind target is utun4 and default port is 5900. Interface names resolve to their first active IPv4 address at startup; an unavailable interface is an error. Use --bind 127.0.0.1 for loopback.
    Default mode is an account listener on one port. Enter a macOS username and password in Screen Sharing; VNC_PASSWORD is ignored.
    Startup checks listener privileges. Start with sudo to serve other accounts or root; a non-root listener warns that it can serve only its own account.
    Ordinary usernames select existing GUI sessions, including locked/off-console desktops. No new macOS login session is created.
    Username root requires the enabled root account's password and a root listener; it selects the current console owner: loginwindow or the logged-in user's desktop. Existing connections stay on their selected session.
    One worker per UID/audit session owns all its client sockets, capture, input, clipboard, and file transfers. No frame relay runs through the listener.
    The account listener requires a viewer supporting ARD security type 30 (including Apple Screen Sharing).
    --display defaults to all on the single listening port; --display 1 selects one display within each account session.
    Explicit --session user and --session console retain the legacy VNC_PASSWORD endpoints for compatibility.
    Legacy --session console follows console sessions, requires sudo, and disables clipboard/file transfer.
    Legacy --session user without --display opens one combined port plus one additional port per display.
    Use --verbose to enable periodic framebuffer update logs.
    Zlib and ZRLE default to zlib-ng with adaptive levels 2/3; system uses levels 1/3.
    Use --zlib-level 0...9 to fix the Zlib level (0 sends stored blocks); auto allows adaptation.
    Cursor defaults to client rendering when available; --cursor embedded includes it in captured frames.
    Plaintext session traffic (--no-encryption), clipboard sharing and file transfer are enabled by default. Password authentication is retained.
    Use --encryption to negotiate Apple encryption, --no-clipboard-sync to disable clipboard sharing, or --no-file-transfer to disable file transfer. The last option for each setting wins.
    With file transfer enabled, --no-encryption enables experimental plaintext operation on a plain VNC URL.
    It suppresses session-record key exchange and refuses encrypted session records. Type-30 account logins still decode the client's AES-wrapped keyboard/mouse events; framebuffer traffic stays unencrypted.
    --clipboard-sync shares text and images with Apple Screen Sharing (text with classic VNC).
    --file-transfer enables file/folder drag and drop with vnc://HOST:PORT/.
    Incoming files are staged in ~/Library/Application Support/mac-vnc-server/Transfers.
    Keep holding to continue with local files when ready, or drag completed rows from Received Files.
    Use --file-drop-mode native to retain the original Finder/promise destination workflow.
    Storage: --transfer-directory /absolute/path, --transfer-limit-gib 10, --transfer-free-gib 1.
    The transfers command reopens received files without starting a server.
    Account authentication always verifies both username and password, independently of the session-encryption setting.
    Use --no-adaptive to disable adaptive FPS, compression, and scale changes.
    Use --service to install and start a per-user LaunchAgent that runs in the UI session.
    The default per-user service needs no password environment and serves only that user. A root listener is started separately.
    Only legacy --session user services require launchctl setenv VNC_PASSWORD before installation.
    Use --service-restart to restart the registered LaunchAgent.
    --no-password is available only with explicit legacy --session user, never on the account listener.
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
            passwordFromEnvironment: passwordFromEnvironment,
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
            transferOptions: transferOptions, nativeFileDrops: nativeFileDrops,
            insecureAllowNoAuth: insecureAllowNoAuth, sessionTarget: sessionTarget,
            transferDirectoryIsExplicit: transferDirectoryIsExplicit
        )
    }

    func withResolvedPassword(_ password: String) -> ServerConfig {
        ServerConfig(
            bindAddress: bindAddress,
            port: port,
            password: password,
            passwordFromEnvironment: false,
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
            transferOptions: transferOptions, nativeFileDrops: nativeFileDrops,
            insecureAllowNoAuth: insecureAllowNoAuth, sessionTarget: sessionTarget,
            transferDirectoryIsExplicit: transferDirectoryIsExplicit
        )
    }
}
