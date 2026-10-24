import Foundation

/// Any server that speaks the OpenAI Chat Completions format: OpenAI itself,
/// OpenRouter, Groq, Ollama, LM Studio, vLLM and the rest. One streaming
/// `POST {base}/chat/completions` per turn, tools as functions.
@MainActor
final class OpenAIBackend: AssistantBackend {
    var onText: ((String) -> Void)?
    var onProgress: ((String) -> Void)?
    let model: AssistantModelConfig
    private let key: String?
    private let session: URLSession

    init(model: AssistantModelConfig, key: String?, session: URLSession = .shared) {
        self.model = model
        self.key = key
        self.session = session
    }

    func requestBody(system: String, tools: [AssistantToolSpec], turns: [AssistantTurn]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.model,
            "stream": true,
            "messages": Self.messages(system: system, turns: turns),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": ["name": tool.name, "description": tool.description, "parameters": tool.schema] as [String: Any],
                ] as [String: Any]
            }
        }
        return body
    }

    static func messages(system: String, turns: [AssistantTurn]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            switch turn {
            case .user(let text):
                messages.append(["role": "user", "content": text])
            case .assistant(let text, let calls, _, _):
                var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
                if !calls.isEmpty {
                    message["tool_calls"] = calls.map { call in
                        let arguments = (try? JSONSerialization.data(withJSONObject: call.input))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        return [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": arguments],
                        ] as [String: Any]
                    }
                }
                messages.append(message)
            case .toolResults(let outcomes):
                for outcome in outcomes {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": outcome.callID,
                        "content": outcome.isError ? "Error: \(outcome.content)" : outcome.content,
                    ])
                }
            }
        }
        return messages
    }

    func send(system: String, tools: [AssistantToolSpec], turns: [AssistantTurn]) async throws -> AssistantReply {
        if !model.isLocal, (key ?? "").isEmpty { throw AssistantClientError.missingKey(model.name) }
        var request = URLRequest(url: try AssistantBackends.endpoint(model.baseURL, "/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, tools: tools, turns: turns))

        var parser = OpenAIStreamParser()
        parser.onText = { [weak self] in self?.onText?($0) }
        parser.onProgress = { [weak self] in self?.onProgress?($0) }
        try await AssistantBackends.stream(request, session: session) { try parser.consume(line: $0) }
        return parser.reply
    }
}

/// Assembles a streamed Chat Completions response.
struct OpenAIStreamParser {
    var onText: ((String) -> Void)?
    var onProgress: ((String) -> Void)?

    private var text = ""
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var finishReason: String?

    var reply: AssistantReply {
        let ordered = calls.keys.sorted().compactMap { calls[$0] }
        let toolCalls = ordered.enumerated().map { offset, call -> AssistantToolCall in
            let id = call.id.isEmpty ? "call_\(offset)" : call.id
            if call.arguments.trimmingCharacters(in: .whitespaces).isEmpty {
                return AssistantToolCall(id: id, name: call.name, input: [:])
            }
            guard let data = call.arguments.data(using: .utf8),
                  let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AssistantToolCall(id: id, name: call.name, input: [:], inputIsInvalid: true)
            }
            return AssistantToolCall(id: id, name: call.name, input: input)
        }
        let stop: AssistantStop
        switch finishReason {
        case "length": stop = .maxTokens
        case "content_filter": stop = .refusal
        default: stop = toolCalls.isEmpty ? .done : .toolUse
        }
        return AssistantReply(text: text, calls: toolCalls, stop: stop, native: nil)
    }

    mutating func consume(line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let error = chunk["error"] as? [String: Any] {
            throw AssistantClientError.stream(error["message"] as? String ?? "The stream failed")
        }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return }

        if let piece = delta["content"] as? String, !piece.isEmpty {
            text += piece
            onText?(piece)
        }
        // Reasoning models on some servers stream their thinking separately.
        if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
            onProgress?(reasoning)
        }
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = call["index"] as? Int ?? calls.count
            var entry = calls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
            if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty, entry.name.isEmpty { entry.name = name }
                entry.arguments += function["arguments"] as? String ?? ""
            }
            calls[index] = entry
        }
    }
}
