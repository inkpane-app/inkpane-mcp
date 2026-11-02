import CoreGraphics
import Foundation
import InkpaneKit
import InkpaneMCP

let usage = """
    inkpane-mcp \(InkpaneServer.version) — MCP server that lets AI agents see your macOS screen.

    Usage:
      inkpane-mcp                Serve MCP over stdio (what MCP clients run).
      inkpane-mcp --require-app  The same, but refuse screen reads unless the Inkpane app is
                                   running (so its permission prompt, exclusions and redaction
                                   always apply).
      inkpane-mcp --http [--port N]
                                   Serve MCP over Streamable HTTP at http://127.0.0.1:N/mcp instead
                                   (default port \(MCPHTTPServer.defaultPort)). Loopback only; clients need the
                                   bearer token in mcp-http.token next to the app's agent.token
                                   (created on first use). Combine with --require-app if you like.
      inkpane-mcp --check        Print Screen Recording permission and Inkpane app status, then exit.
      inkpane-mcp --version      Print the version and exit.

    Environment:
      INKPANE_MCP_OUTPUT_DIR    Where captures are saved (default: $TMPDIR/inkpane-mcp).
      INKPANE_APP_DIR           Where the Inkpane app's socket and token are
                                  (default: ~/Library/Application Support/app.inkpane.Inkpane).
      INKPANE_MCP_REQUIRE_APP   1 does the same as --require-app.
      INKPANE_MCP_EXCLUDE_APPS  Comma-separated bundle ids to leave out of captures and window
                                  lists when the app isn't running (the app's own list applies
                                  when it is).

    """

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func serve(requirement: AppRequirement?) async {
    // ScreenCaptureKit needs a window-server connection; touching Core
    // Graphics display APIs initializes it for a plain command-line process.
    _ = CGMainDisplayID()
    do {
        try await InkpaneServer.run(requirement: requirement)
    } catch {
        printError("inkpane-mcp: \(error.localizedDescription)")
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--version", "-v":
    print(InkpaneServer.version)
case "--help", "-h":
    print(usage, terminator: "")
case "--check":
    let chain = HostApp.detectChain()
    print("Launched by (closest first): \(chain.isEmpty ? "unknown" : chain.map { "\($0.name) — \($0.bundlePath)" }.joined(separator: "; "))")
    let requirement = arguments.contains("--require-app") ? AppRequirement.required : AppRequirement.fromEnvironment()
    let bridge = BridgeClient(timeout: 3)
    var appRunning = false
    do {
        let hello = try await bridge.hello()
        appRunning = true
        print("Inkpane app: running (\(hello.app) \(hello.appVersion), protocol \(hello.protocolVersion)) at \(bridge.location)")
        if hello.methods.contains(BridgeMethod.capture.rawValue) {
            print("  Screen reads go through the app: it asks before a new agent first looks, applies its exclusion list and redaction, and shows its indicator.")
        } else {
            print("  This app version doesn't handle screen reads; inkpane-mcp captures by itself.")
        }
    } catch {
        print("Inkpane app: not available. \(error.localizedDescription)")
        print("  (annotate_screen, clear_annotations, wait_for_user_annotation and screen://assets need it.)")
        if requirement == .required {
            print("  --require-app / INKPANE_MCP_REQUIRE_APP is set, so screen reads will fail until the app runs.")
        } else {
            print("  Screen reads run standalone: no permission prompt, exclusion list or redaction from the app.")
        }
    }
    let exclusions = StandaloneExclusions.fromEnvironment()
    if !exclusions.bundleIDs.isEmpty {
        print("Standalone exclusions (\(StandaloneExclusions.environmentKey)): \(exclusions.bundleIDs.joined(separator: ", "))")
    }
    print("Accessibility (for get_ui_tree without the app): \(AccessibilityPermission.isGranted ? "granted" : "not granted")")
    if ScreenRecordingPermission.isGranted {
        print("Screen Recording: granted")
    } else {
        print("Screen Recording: NOT granted")
        print(InkpaneError.permissionDenied().localizedDescription)
        if !appRunning { exit(1) }
    }
default:
    guard let options = ServeOptions.parse(arguments) else {
        printError("Unknown argument: \(arguments.joined(separator: " "))\n")
        printError(usage)
        exit(64)
    }
    let requirement: AppRequirement? = options.requireApp ? .required : nil
    if options.http {
        _ = CGMainDisplayID()
        do {
            try await InkpaneServer.runHTTP(port: options.port, requirement: requirement, log: printError)
        } catch {
            printError("inkpane-mcp: \(error.localizedDescription)")
            exit(1)
        }
    } else {
        await serve(requirement: requirement)
    }
}
