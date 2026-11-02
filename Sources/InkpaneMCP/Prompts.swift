import MCP

// MCP prompts (`prompts/list`, `prompts/get`): ready-made workflows that chain Inkpane's tools.
// Clients usually show them as slash commands (e.g. `/mcp__inkpane__report_ui_bug` in Claude
// Code). Each returns one user message that tells the agent which tools to call, in what order.

public enum PromptCatalog {
    public static let reportUIBug = "report_ui_bug"
    public static let explainErrorOnScreen = "explain_error_on_screen"

    public static let prompts: [Prompt] = [
        Prompt(
            name: reportUIBug,
            title: "Report a UI bug",
            description: "Ask the user to circle the problem on screen, capture it, read its text and accessibility details, and write a bug report with steps to reproduce.",
            arguments: [
                .init(name: "app", title: "App", description: "The app or window the bug is in (name or bundle id). Optional.", required: false),
                .init(name: "expected", title: "Expected behaviour", description: "What should have happened, if you already know. Optional.", required: false),
                .init(name: "steps", title: "Steps so far", description: "What the user did before the bug appeared, if known. Optional.", required: false),
            ]),
        Prompt(
            name: explainErrorOnScreen,
            title: "Explain the error on screen",
            description: "Capture and read the frontmost window (or an app's window), explain the error message it shows and how to fix it, and point at it on screen.",
            arguments: [
                .init(name: "app", title: "App", description: "Read this app's frontmost window instead of the frontmost window. Optional.", required: false),
                .init(name: "language", title: "Answer language", description: "Language for the explanation, e.g. English or 简体中文. Defaults to the user's language.", required: false),
            ]),
    ]

    public static func get(name: String, arguments: [String: String]?) throws -> GetPrompt.Result {
        var args: [String: String] = [:]
        for (key, value) in arguments ?? [:] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { args[key] = String(trimmed.prefix(2000)) }
        }
        guard let prompt = prompts.first(where: { $0.name == name }) else {
            throw MCPError.invalidParams("Unknown prompt: \(name). Available: \(prompts.map(\.name).joined(separator: ", ")).")
        }
        let known = Set((prompt.arguments ?? []).map(\.name))
        if let unknown = args.keys.sorted().first(where: { !known.contains($0) }) {
            throw MCPError.invalidParams("Unknown argument \(unknown) for \(name). Allowed: \(known.sorted().joined(separator: ", ")).")
        }
        let text: String = switch name {
        case reportUIBug: reportUIBugText(app: args["app"], expected: args["expected"], steps: args["steps"])
        default: explainErrorText(app: args["app"], language: args["language"])
        }
        return GetPrompt.Result(description: prompt.description, messages: [.user(.text(text: text))])
    }

    static func reportUIBugText(app: String?, expected: String?, steps: String?) -> String {
        let scope = app.map { " in \($0)" } ?? ""
        var known: [String] = []
        if let expected { known.append("Expected behaviour (from the user): \(expected)") }
        if let steps { known.append("What the user did (from the user): \(steps)") }
        return """
            Help me report a UI bug\(scope). Use the Inkpane tools in this order:

            1. Call `wait_for_user_annotation` with a prompt such as "Circle the part of the screen that shows the bug" \
            (shape rectangle). If the result is "cancelled" or "timed_out", ask me in chat what to look at instead of guessing. \
            It returns the region in screen points, a screenshot of it and the text in it.
            2. Call `list_windows` and find the window that contains the region\(app.map { " (it should belong to \($0))" } ?? ""). \
            Capture that whole window with `capture_window` so the report shows the context, not just the selection.
            3. Call `get_ui_tree` for that window with `text` or `roles` matching what I circled (for example the button title \
            from the OCR text) to get the exact roles, labels, identifiers, enabled/focused state and frames of the elements involved. \
            If it fails because Accessibility permission is missing, use `read_screen_ocr` on the window instead and say so.
            4. Write the bug report in Markdown:
               - **Title**: one line, specific ("Save button stays disabled after editing the name field").
               - **Environment**: app and window title, plus what the tools told you (display, window size).
               - **Steps to reproduce**: numbered. Only include steps you know from me or can see on screen; mark anything you infer \
            as "(inferred)" and ask me to confirm. Never invent steps.
               - **Expected** and **Actual** behaviour.
               - **Evidence**: the saved screenshot paths, the selected region's coordinates, and the relevant UI elements \
            (role, title/label, identifier, state).
               - **Notes**: anything that looks related (error text, disabled controls, truncated labels).
            5. Show me the report and ask whether anything is missing. If the tools reported that some apps were left out or text \
            was redacted for privacy, keep it that way; don't try to recover hidden content.
            \(known.isEmpty ? "" : "\n" + known.joined(separator: "\n"))
            """
    }

    static func explainErrorText(app: String?, language: String?) -> String {
        let target = app.map { "the frontmost window of \($0) (`app: \"\($0)\"`)" } ?? "the frontmost window"
        return """
            Explain the error that is on my screen right now. Use the Inkpane tools:

            1. Call `list_windows` and pick \(target). If the frontmost window is a terminal or this chat, ask me which window \
            shows the error.
            2. Call `read_screen_ocr` for that window (`window_id`) with `include_image: true` to get the text, each line's \
            `screen_box` and a screenshot. For dialogs and sheets, `get_ui_tree` with `roles: ["AXStaticText", "AXButton"]` gives the \
            exact message and button titles; use it when OCR is unclear.
            3. Find the error message (dialog text, red text, a stack trace, a failed build line). Quote it exactly.
            4. Explain\(language.map { " in \($0)" } ?? ""): what the error means, the most likely cause given what else is on screen, and \
            concrete steps to fix it, most likely first. Say what you're unsure about.
            5. Point at it: call `annotate_screen` with a `box` around the error text, using the union of the `screen_box` values of its \
            OCR lines (screen points), with a short `label` such as "This error", and `ttl_seconds: 20`. If the Inkpane app isn't \
            running, skip this step and describe where the error is instead.

            If the tools say a window was excluded or text was redacted for privacy, don't try to work around it; ask me to paste the \
            text instead.
            """
    }
}
