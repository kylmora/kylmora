import Foundation

/// The browser tools the model can call from the chat, each backed by the agent.
@MainActor
enum AssistantTools {
    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> AssistantToolSpec {
        AssistantToolSpec(name: name, description: description, schema: [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ])
    }

    private static let ref: [String: Any] = ["type": "string", "description": "A ref from read_page, such as \"@12\"."]
    private static let label: [String: Any] = ["type": "string", "description": "A 3-6 word description of the action, shown beside the cursor."]

    static let definitions: [AssistantToolSpec] = [
        tool("read_page", "Lists the controls and headings on the current page, each actionable element with an @ref, its role, name, value and state. Use before clicking or typing.",
             ["scope": ["type": "string", "enum": ["viewport", "full_page"], "description": "viewport (default) or the whole page."]]),
        tool("get_page_text", "Returns the page's title, URL and readable text, for answering questions about its content."),
        tool("click", "Clicks an element with the real mouse. The page scrolls it into view first.",
             ["ref": ref, "label": label], required: ["ref"]),
        tool("type_text", "Types text key by key. With ref, clicks that field first; with clear, empties it first. Never use for passwords or payment details.",
             ["text": ["type": "string"], "ref": ref, "clear": ["type": "boolean"]], required: ["text"]),
        tool("press_key", "Presses a key or chord: Enter, Tab, Escape, ArrowDown, Backspace, Meta+a.",
             ["key": ["type": "string"]], required: ["key"]),
        tool("scroll", "Scrolls the page with the mouse wheel.",
             ["deltaY": ["type": "number", "description": "Pixels; positive scrolls down."]], required: ["deltaY"]),
        tool("navigate", "Loads a URL in the current tab and waits for it.",
             ["url": ["type": "string"]], required: ["url"]),
        tool("open_tab", "Opens a URL in a new tab in the user's current profile and switches to it.",
             ["url": ["type": "string"]], required: ["url"]),
        tool("hand_off_to_user", "Gives the page to the user for a sign-in, captcha, two-factor code or payment. Stop after calling it.",
             ["reason": ["type": "string", "description": "What the user needs to do."]], required: ["reason"]),
    ]

    /// The step line the panel shows for a call.
    static func describe(name: String, input: [String: Any]) -> String {
        let ref = input["ref"] as? String ?? ""
        switch name {
        case "read_page": return "→ Reading the page"
        case "get_page_text": return "→ Reading the page's text"
        case "click": return "→ " + ((input["label"] as? String) ?? "Clicking \(ref)")
        case "type_text": return "→ Typing “\(input["text"] as? String ?? "")”"
        case "press_key": return "→ Pressing \(input["key"] as? String ?? "")"
        case "scroll": return "→ Scrolling"
        case "navigate", "open_tab": return "→ Opening \(input["url"] as? String ?? "")"
        case "hand_off_to_user": return "→ Over to you: \(input["reason"] as? String ?? "")"
        default: return "→ \(name)"
        }
    }

    static func run(name: String, input: [String: Any], browser: BrowserSession?) async throws -> String {
        let agent = AgentController.shared
        func string(_ key: String) throws -> String {
            guard let value = input[key] as? String, !value.isEmpty else {
                throw AgentError.invalidTarget("Missing '\(key)'")
            }
            return value
        }
        func url(_ key: String) throws -> URL {
            let text = try string(key)
            guard let url = URL(string: text.contains("://") ? text : "https://\(text)") else {
                throw AgentError.invalidTarget("Not a URL: \(text)")
            }
            return url
        }

        switch name {
        case "read_page":
            let result = try await agent.takeSnapshot(scope: input["scope"] as? String)
            return result["markdown"] as? String ?? "(empty page)"
        case "get_page_text":
            return try await agent.pageText()
        case "click":
            let result = try await agent.click(ref: try string("ref"), label: input["label"] as? String)
            return "Clicked \(result["ref"] ?? "")."
        case "type_text":
            let text = try string("text")
            _ = try await agent.type(text: text, ref: input["ref"] as? String, clear: (input["clear"] as? Bool) ?? false)
            return "Typed \(text.count) characters."
        case "press_key":
            let key = try string("key")
            _ = try await agent.press(key: key)
            return "Pressed \(key)."
        case "scroll":
            let delta = (input["deltaY"] as? Double) ?? Double(input["deltaY"] as? Int ?? 400)
            _ = try await agent.scroll(deltaY: delta)
            return "Scrolled \(Int(delta))px."
        case "navigate":
            let result = try await agent.navigate(url: try url("url"))
            return "Loaded \(result["url"] ?? "") — \(result["title"] ?? "")"
        case "open_tab":
            let result = try agent.openTab(url: try url("url"))
            return "Opened a new tab (\(result["id"] ?? ""))."
        case "hand_off_to_user":
            let result = agent.handOff(reason: try string("reason"))
            return result["message"] as? String ?? "Handed off."
        default:
            throw AgentError.invalidTarget("Unknown tool \(name)")
        }
    }
}
