import Foundation

// MARK: - The conversation, independent of any one API

/// A tool Claude or another model may call, described once and translated into
/// each API's own shape.
struct AssistantToolSpec {
    let name: String
    let description: String
    let schema: [String: Any]
}

struct AssistantToolCall {
    let id: String
    let name: String
    let input: [String: Any]
    /// The streamed arguments did not parse; the call is answered with an
    /// error instead of being run.
    var inputIsInvalid = false
}

struct AssistantToolOutcome {
    let callID: String
    let content: String
    let isError: Bool
}

/// One entry in the transcript the session keeps.
enum AssistantTurn {
    case user(String)
    /// `native` holds the response exactly as an API returned it, so it can go
    /// back unchanged to the same API (Anthropic's thinking blocks must).
    case assistant(text: String, calls: [AssistantToolCall], native: [[String: Any]]?, format: AssistantAPIFormat)
    case toolResults([AssistantToolOutcome])
}

enum AssistantStop: Equatable {
    case done
    case toolUse
    case maxTokens
    case refusal
}

struct AssistantReply {
    var text: String
    var calls: [AssistantToolCall]
    var stop: AssistantStop
    var native: [[String: Any]]?
}

enum AssistantClientError: LocalizedError {
    case missingKey(String)
    case badURL(String)
    case http(Int, String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let name): return "Add an API key for \(name) to use it."
        case .badURL(let url): return "The model's address isn't a valid URL: \(url)"
        case .http(let status, let message): return "The model's server answered \(status): \(message)"
        case .stream(let message): return "The model's server reported an error: \(message)"
        }
    }
}

/// Talks to one kind of API.
@MainActor
protocol AssistantBackend: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onProgress: ((String) -> Void)? { get set }
    func send(system: String, tools: [AssistantToolSpec], turns: [AssistantTurn]) async throws -> AssistantReply
}

@MainActor
enum AssistantBackends {
    static func make(for model: AssistantModelConfig, key: String?) -> AssistantBackend {
        switch model.format {
        case .anthropic: return AnthropicBackend(model: model, key: key ?? "")
        case .openai: return OpenAIBackend(model: model, key: key)
        }
    }

    /// The URL for `path` under a model's base address.
    static func endpoint(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path), url.scheme?.hasPrefix("http") == true else {
            throw AssistantClientError.badURL(base)
        }
        return url
    }

    static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8)
        }
        if let error = json["error"] as? [String: Any] { return error["message"] as? String }
        return json["error"] as? String ?? json["message"] as? String
    }

    /// Streams `request`, handing each server-sent-event line to `consume`.
    static func stream(_ request: URLRequest, session: URLSession, consume: (String) throws -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw AssistantClientError.http(status, errorMessage(in: raw) ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try consume(line)
        }
    }
}

// MARK: - Anthropic Messages API

/// Claude over raw HTTP. Swift has no official Anthropic SDK, so this speaks
/// the documented wire format: one streaming `POST /v1/messages` per turn.
@MainActor
final class AnthropicBackend: AssistantBackend {
    static let apiVersion = "2026-10-21"

    var onText: ((String) -> Void)?
    var onProgress: ((String) -> Void)?
    let model: AssistantModelConfig
    private let key: String
    private let session: URLSession

    init(model: AssistantModelConfig, key: String, session: URLSession = .shared) {
        self.model = model
        self.key = key
        self.session = session
    }

    /// Current Claude models take adaptive thinking, effort and progress
    /// updates; an older model a user adds by hand gets a plain request.
    var isCurrentGeneration: Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"].contains { model.model.hasPrefix($0) }
    }

    /// Server-side refusal fallback: the Opus 5 line, Sonnet 5.5 and Fable.
    var supportsServerFallback: Bool {
        ["claude-opus-5", "claude-sonnet-5-5", "claude-fable-5"].contains { model.model.hasPrefix($0) }
    }

    var betaHeader: String? {
        var betas: [String] = []
        if isCurrentGeneration { betas.append("thinking-display-updates-2026-08-18") }
        if supportsServerFallback { betas.append("server-side-fallback-2026-07-01") }
        return betas.isEmpty ? nil : betas.joined(separator: ",")
    }

    func requestBody(system: String, tools: [AssistantToolSpec], turns: [AssistantTurn]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.model,
            "max_tokens": 64000,
            "stream": true,
            "system": system,
            "tools": tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.schema,
                    // Streamed tool input arrives as it is generated; the
                    // session validates it before running anything.
                    "eager_input_streaming": true,
                ] as [String: Any]
            },
            "messages": Self.messages(for: turns),
            // Caches the stable prefix: tools, system, earlier turns.
            "cache_control": ["type": "ephemeral"],
        ]
        if isCurrentGeneration {
            // Thinking stays on; "updates" returns the progress notes between
            // tool calls as short thinking text while reasoning stays hidden.
            body["thinking"] = ["type": "adaptive", "display": "updates"]
            body["output_config"] = ["effort": "medium"]
        }
        if supportsServerFallback { body["fallbacks"] = "default" }
        return body
    }

    /// The transcript in Messages API shape. Consecutive user-side entries are
    /// merged so roles alternate.
    static func messages(for turns: [AssistantTurn]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        func appendUser(_ blocks: [[String: Any]]) {
            if var last = messages.last, last["role"] as? String == "user", var content = last["content"] as? [[String: Any]] {
                content.append(contentsOf: blocks)
                last["content"] = content
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": "user", "content": blocks])
            }
        }
        for turn in turns {
            switch turn {
            case .user(let text):
                appendUser([["type": "text", "text": text]])
            case .toolResults(let outcomes):
                appendUser(outcomes.map { outcome in
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": outcome.callID, "content": outcome.content]
                    if outcome.isError { block["is_error"] = true }
                    return block
                })
            case .assistant(let text, let calls, let native, let format):
                if format == .anthropic, let native {
                    messages.append(["role": "assistant", "content": native])
                } else {
                    var blocks: [[String: Any]] = []
                    if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                    blocks += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] }
                    if blocks.isEmpty { blocks.append(["type": "text", "text": "…"]) }
                    messages.append(["role": "assistant", "content": blocks])
                }
            }
        }
        return messages
    }

    func send(system: String, tools: [AssistantToolSpec], turns: [AssistantTurn]) async throws -> AssistantReply {
        guard !key.isEmpty else { throw AssistantClientError.missingKey(model.name) }
        var request = URLRequest(url: try AssistantBackends.endpoint(model.baseURL, "/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let betaHeader { request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, tools: tools, turns: turns))

        var parser = AnthropicStreamParser()
        parser.onText = { [weak self] in self?.onText?($0) }
        parser.onProgress = { [weak self] in self?.onProgress?($0) }
        try await AssistantBackends.stream(request, session: session) { try parser.consume(line: $0) }
        return parser.reply
    }
}

/// Assembles a streamed Messages API response from its server-sent events.
struct AnthropicStreamParser {
    var onText: ((String) -> Void)?
    var onProgress: ((String) -> Void)?

    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var invalid: Set<Int> = []
    private var stopReason: String?

    var content: [[String: Any]] { blocks.keys.sorted().compactMap { blocks[$0] } }
    var invalidToolInputs: Set<Int> { invalid }

    var reply: AssistantReply {
        let ordered = blocks.keys.sorted()
        let text = ordered.compactMap { blocks[$0] }.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        let calls = ordered.compactMap { index -> AssistantToolCall? in
            guard let block = blocks[index], block["type"] as? String == "tool_use" else { return nil }
            return AssistantToolCall(
                id: block["id"] as? String ?? "",
                name: block["name"] as? String ?? "",
                input: block["input"] as? [String: Any] ?? [:],
                inputIsInvalid: invalid.contains(index)
            )
        }
        let stop: AssistantStop
        switch stopReason {
        case "tool_use": stop = .toolUse
        case "max_tokens", "model_context_window_exceeded": stop = .maxTokens
        case "refusal": stop = .refusal
        default: stop = .done
        }
        return AssistantReply(text: text, calls: calls, stop: stop, native: content)
    }

    mutating func consume(line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return }
            blocks[index] = block
            if block["type"] as? String == "tool_use" { partialJSON[index] = "" }

        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any],
                  var block = blocks[index] else { return }
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                block["text"] = (block["text"] as? String ?? "") + text
                onText?(text)
            case "thinking_delta":
                let text = delta["thinking"] as? String ?? ""
                block["thinking"] = (block["thinking"] as? String ?? "") + text
                if !text.isEmpty { onProgress?(text) }
            case "signature_delta":
                block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            default:
                break
            }
            blocks[index] = block

        case "content_block_stop":
            guard let index = event["index"] as? Int, var block = blocks[index],
                  block["type"] as? String == "tool_use" else { return }
            let json = partialJSON[index] ?? ""
            if json.isEmpty {
                block["input"] = block["input"] ?? [String: Any]()
            } else if let data = json.data(using: .utf8),
                      let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                block["input"] = input
            } else {
                block["input"] = [String: Any]()
                invalid.insert(index)
            }
            blocks[index] = block

        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }

        case "error":
            let error = event["error"] as? [String: Any]
            throw AssistantClientError.stream(error?["message"] as? String ?? "The stream failed")

        default:
            break
        }
    }
}
