import Foundation
import MCP
import InkpaneKit
import Testing
@testable import InkpaneMCP

@Suite struct PromptTests {
    private func text(_ result: GetPrompt.Result) -> String {
        result.messages.compactMap { message -> String? in
            if case .text(let text) = message.content { text } else { nil }
        }.joined()
    }

    @Test func catalogListsBothPromptsWithOptionalArguments() {
        #expect(PromptCatalog.prompts.map(\.name) == ["report_ui_bug", "explain_error_on_screen"])
        for prompt in PromptCatalog.prompts {
            #expect(prompt.description?.isEmpty == false)
            #expect(prompt.arguments?.allSatisfy { $0.required == false } == true, "\(prompt.name) works without arguments")
        }
    }

    @Test func reportUIBugWalksThroughTheTools() throws {
        let result = try PromptCatalog.get(name: PromptCatalog.reportUIBug, arguments: ["app": "Simulator", "expected": "The Save button saves", "steps": "  "])
        #expect(result.messages.count == 1)
        #expect(result.messages.first?.role == .user)
        let body = text(result)
        let order = ["wait_for_user_annotation", "capture_window", "get_ui_tree", "Steps to reproduce"].map { body.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted(), "the tools come in order")
        #expect(body.contains("in Simulator"))
        #expect(body.contains("Expected behaviour (from the user): The Save button saves"))
        #expect(!body.contains("What the user did"), "blank arguments are ignored")
        #expect(body.contains("Never invent steps"))
    }

    @Test func explainErrorPointsAtIt() throws {
        let plain = text(try PromptCatalog.get(name: PromptCatalog.explainErrorOnScreen, arguments: nil))
        #expect(plain.contains("the frontmost window"))
        #expect(plain.contains("read_screen_ocr") && plain.contains("annotate_screen"))
        let targeted = text(try PromptCatalog.get(name: PromptCatalog.explainErrorOnScreen, arguments: ["app": "Xcode", "language": "简体中文"]))
        #expect(targeted.contains("`app: \"Xcode\"`"))
        #expect(targeted.contains("Explain in 简体中文"))
    }

    @Test func unknownPromptsAndArgumentsAreRejected() {
        #expect(throws: MCPError.self) { try PromptCatalog.get(name: "nope", arguments: nil) }
        #expect(throws: MCPError.self) { try PromptCatalog.get(name: PromptCatalog.reportUIBug, arguments: ["colour": "red"]) }
    }

    @Test func theServerAdvertisesAndServesThem() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let tools = InkpaneTools(bridge: BridgeClient(location: BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbnone-\(UUID().uuidString.prefix(8))"))))
        let server = await InkpaneServer.makeServer(tools: tools)
        try await server.start(transport: serverTransport)
        let client = Client(name: "prompt-test", version: "1.0")
        let initialized = try await client.connect(transport: clientTransport)
        #expect(initialized.capabilities.prompts != nil)

        let listed = try await client.listPrompts()
        #expect(listed.prompts.map(\.name) == PromptCatalog.prompts.map(\.name))
        let got = try await client.getPrompt(name: PromptCatalog.explainErrorOnScreen, arguments: ["app": "Safari"])
        #expect(got.messages.count == 1)
        let toolNames = try await client.listTools().tools.map(\.name)
        #expect(toolNames.contains(ToolCatalog.getUITree) && toolNames.contains(ToolCatalog.diffScreenshots))
        await client.disconnect()
        await server.stop()
    }
}
