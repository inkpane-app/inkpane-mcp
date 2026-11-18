import Foundation
import MCP
import InkpaneKit

public enum InkpaneServer {
    public static let name = "inkpane-mcp"
    public static let version = "0.13.0"

    static let instructions = """
        Inkpane gives you eyes on the user's macOS screen. Use list_windows (or the \
        screen://windows/active resource) to find windows and displays, capture_window / \
        capture_screen / capture_region to see them, and read_screen_ocr when you only need \
        the text and its positions. All coordinates are global screen points with the origin at \
        the top-left of the main display. Captures are also saved as PNG files; their paths are \
        in the text result. When the Inkpane menu bar app is running you can also point at \
        things: annotate_screen draws boxes, arrows, text and highlights on the user's screen \
        (clear_annotations removes them), and wait_for_user_annotation asks the user to select \
        a region and returns it with a screenshot and its text; record_action records the screen \
        to an MP4 (with your annotations in the video) and returns the file's path; \
        screen://assets/recent lists the user's recent captures. get_ui_tree returns a window's \
        accessibility tree (roles, labels, identifiers, frames), and diff_screenshots shows what \
        changed between two screenshots (or between one and the screen now). With the app \
        running, the user is asked once before you can see the screen, some apps are excluded and \
        personal data may be blacked out; respect a refusal instead of trying to work around it.
        """

    /// Builds a server with all Inkpane tools and resources registered.
    public static func makeServer(tools: InkpaneTools = .fromEnvironment()) async -> Server {
        let server = Server(
            name: name,
            version: version,
            title: "Inkpane",
            instructions: instructions,
            capabilities: .init(
                prompts: .init(listChanged: false), resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await tools.call(name: params.name, arguments: params.arguments)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: ToolCatalog.resources)
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: ToolCatalog.resourceTemplates)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            try await tools.readResource(uri: params.uri)
        }
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: PromptCatalog.prompts)
        }
        await server.withMethodHandler(GetPrompt.self) { params in
            try PromptCatalog.get(name: params.name, arguments: params.arguments)
        }
        return server
    }

    /// What the Inkpane app shows the user about this client.
    public static func clientInfo(_ info: Client.Info) -> BridgeClientInfo {
        BridgeClientInfo(name: info.name, title: info.title, version: info.version, via: "\(name) \(version)")
    }

    /// Serves MCP over stdin/stdout until the client disconnects.
    public static func run(requirement: AppRequirement? = nil) async throws {
        var tools = InkpaneTools.fromEnvironment()
        if let requirement { tools.requirement = requirement }
        let identity = tools.bridge.identity
        let server = await makeServer(tools: tools)
        try await server.start(transport: BlockingStdioTransport()) { info, _ in
            identity.info = clientInfo(info)
        }
        await server.waitUntilCompleted()
    }
}
