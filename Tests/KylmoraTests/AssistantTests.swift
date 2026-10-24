import Foundation
import Testing
@testable import Kylmora

@Suite("AI assistant: providers and wire formats", .serialized)
@MainActor
struct AssistantTests {
    private func model(_ format: AssistantAPIFormat, _ id: String, base: String) -> AssistantModelConfig {
        AssistantModelConfig(id: UUID(), name: id, format: format, baseURL: base, model: id)
    }

    @Test("Anthropic: a streamed turn assembles text, thinking with its signature, and tool input")
    func anthropicStream() throws {
        var parser = AnthropicStreamParser()
        var streamed = ""
        var progress = ""
        parser.onText = { streamed += $0 }
        parser.onProgress = { progress += $0 }
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Reading the page."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"look."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"click","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"ref\": \"@"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"4\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#,
        ]
        for event in events {
            try parser.consume(line: "event: x")
            try parser.consume(line: "data: " + event)
        }
        let reply = parser.reply
        #expect(streamed == "Let me look.")
        #expect(progress == "Reading the page.")
        #expect(reply.stop == .toolUse)
        #expect(reply.text == "Let me look.")
        #expect(reply.native?[0]["signature"] as? String == "sig123")
        #expect(reply.calls.first?.input["ref"] as? String == "@4")
        #expect(reply.calls.first?.inputIsInvalid == false)
    }

    @Test("Anthropic: tool input that does not parse is flagged, and stream errors throw")
    func anthropicBadInput() throws {
        var parser = AnthropicStreamParser()
        try parser.consume(line: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"click","input":{}}}"#)
        try parser.consume(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"ref\": "}}"#)
        try parser.consume(line: #"data: {"type":"content_block_stop","index":0}"#)
        #expect(parser.reply.calls.first?.inputIsInvalid == true)
        #expect(throws: AssistantClientError.self) {
            try parser.consume(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test("Anthropic: current models get adaptive thinking and fallbacks; older and Haiku do not")
    func anthropicRequest() {
        let opus = AnthropicBackend(model: AssistantConfigStore.builtIns[0], key: "k")
        let body = opus.requestBody(system: "s", tools: AssistantTools.definitions, turns: [.user("hi")])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(body["temperature"] == nil)
        #expect(opus.betaHeader?.contains("server-side-fallback-2026-07-01") == true)
        #expect((body["tools"] as? [[String: Any]])?.allSatisfy { $0["eager_input_streaming"] as? Bool == true } == true)

        let haiku = AnthropicBackend(model: AssistantConfigStore.builtIns[2], key: "k")
        #expect(haiku.requestBody(system: "s", tools: [], turns: [])["fallbacks"] == nil)

        let older = AnthropicBackend(model: model(.anthropic, "claude-3-5-haiku-latest", base: "https://api.anthropic.com/v1"), key: "k")
        let olderBody = older.requestBody(system: "s", tools: [], turns: [])
        #expect(olderBody["thinking"] == nil)
        #expect(older.betaHeader == nil)
    }

    @Test("OpenAI format: deltas assemble text and tool calls; [DONE] is ignored")
    func openAIStream() throws {
        var parser = OpenAIStreamParser()
        var streamed = ""
        parser.onText = { streamed += $0 }
        let chunks = [
            #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Sure, "}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"clicking."}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"click","arguments":"{\"ref\":"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"@7\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        for chunk in chunks { try parser.consume(line: "data: " + chunk) }
        try parser.consume(line: "data: [DONE]")
        let reply = parser.reply
        #expect(streamed == "Sure, clicking.")
        #expect(reply.stop == .toolUse)
        #expect(reply.calls.count == 1)
        #expect(reply.calls[0].id == "call_a")
        #expect(reply.calls[0].name == "click")
        #expect(reply.calls[0].input["ref"] as? String == "@7")
    }

    @Test("OpenAI format: the transcript maps to system, tool_calls and tool messages")
    func openAIMessages() {
        let call = AssistantToolCall(id: "call_1", name: "read_page", input: [:])
        let turns: [AssistantTurn] = [
            .user("hi"),
            .assistant(text: "", calls: [call], native: nil, format: .openai),
            .toolResults([AssistantToolOutcome(callID: "call_1", content: "page", isError: false)]),
        ]
        let messages = OpenAIBackend.messages(system: "sys", turns: turns)
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect((messages[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")

        let backend = OpenAIBackend(model: model(.openai, "my-model", base: "http://localhost:11434/v1"), key: nil)
        let body = backend.requestBody(system: "s", tools: AssistantTools.definitions, turns: turns)
        #expect((body["tools"] as? [[String: Any]])?.first?["type"] as? String == "function")
    }

    @Test("A conversation started on one format carries over to the other")
    func switchingFormats() {
        let call = AssistantToolCall(id: "toolu_1", name: "read_page", input: [:])
        let turns: [AssistantTurn] = [
            .user("hi"),
            .assistant(text: "Looking.", calls: [call], native: nil, format: .openai),
            .toolResults([AssistantToolOutcome(callID: "toolu_1", content: "page", isError: false)]),
            .user("and?"),
        ]
        let messages = AnthropicBackend.messages(for: turns)
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let last = messages[2]["content"] as? [[String: Any]]
        #expect(last?.map { $0["type"] as? String } == ["tool_result", "text"])
    }

    @Test("Models: local servers need no key, keys are shared per server, endpoints join cleanly")
    func modelConfig() throws {
        #expect(model(.openai, "llama", base: "http://localhost:11434/v1").isLocal)
        #expect(!model(.openai, "x", base: "https://api.openai.com/v1").isLocal)
        #expect(model(.openai, "a", base: "https://api.openai.com/v1").keyAccount == model(.openai, "b", base: "https://api.openai.com/v1/").keyAccount)
        #expect(AssistantConfigStore.builtIns[0].keyAccount == "anthropic-api-key")
        #expect(try AssistantBackends.endpoint("https://api.openai.com/v1/", "/chat/completions").absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(throws: AssistantClientError.self) { try AssistantBackends.endpoint("not a url", "/x") }
    }

    @Test("Custom models are saved, chosen and removed")
    func customModels() {
        let defaults = UserDefaults(suiteName: "AssistantTests-\(UUID())")!
        let previous = AssistantConfigStore.defaults
        AssistantConfigStore.defaults = defaults
        defer { AssistantConfigStore.defaults = previous }

        let custom = model(.openai, "local-llama", base: "http://localhost:11434/v1")
        AssistantConfigStore.save(custom)
        #expect(AssistantConfigStore.allModels.contains(custom))
        AssistantConfigStore.selected = custom
        #expect(AssistantConfigStore.selected == custom)
        #expect(AssistantConfigStore.isReady(custom))
        AssistantConfigStore.remove(custom)
        #expect(!AssistantConfigStore.allModels.contains(custom))
        #expect(AssistantConfigStore.selected == AssistantConfigStore.builtIns[0])
    }
}
