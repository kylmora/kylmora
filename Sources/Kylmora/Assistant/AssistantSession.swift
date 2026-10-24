import Foundation

/// One line in the chat as the panel shows it.
enum AssistantChatItem: Equatable {
    case user(String)
    case assistant(String)
    /// What the model is doing between replies: a progress note or a tool step.
    case step(String)
    case error(String)
}

/// A conversation about the page the user is on, with whichever model they chose.
///
/// The model reads and drives the page through the same agent the CLI uses
/// (`AgentController`), so its clicks and typing are real input from the
/// visible cursor, under the glow and the "Take over" pill. The transcript is
/// kept in a neutral form, so switching from Claude to an OpenAI-format model
/// mid-chat carries the conversation over.
@MainActor
final class AssistantSession {
    private(set) var items: [AssistantChatItem] = [] {
        didSet { onChange?() }
    }
    private(set) var isRunning = false {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    weak var browser: BrowserSession?
    private var turns: [AssistantTurn] = []
    private var task: Task<Void, Never>?

    init(browser: BrowserSession?) {
        self.browser = browser
    }

    func reset() {
        task?.cancel()
        task = nil
        turns = []
        items = []
        isRunning = false
    }

    func stop() {
        task?.cancel()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        let model = AssistantConfigStore.selected
        let key = AssistantConfigStore.key(for: model)
        guard model.isLocal || key != nil else {
            items.append(.error(AssistantClientError.missingKey(model.name).localizedDescription))
            return
        }
        items.append(.user(trimmed))
        turns.append(.user(contextLine() + trimmed))

        // The model works on the tab the user is looking at.
        if let tab = browser?.activeTab {
            _ = AgentController.shared.selectTab(id: tab.id)
        }
        isRunning = true
        let backend = AssistantBackends.make(for: model, key: key)
        backend.onText = { [weak self] in self?.appendAssistantText($0) }
        backend.onProgress = { [weak self] in self?.appendProgress($0) }
        task = Task { [weak self] in
            await self?.runLoop(backend: backend, format: model.format)
        }
    }

    /// Where the user is, sent with each message rather than in the system
    /// prompt so a cached prefix stays the same.
    private func contextLine() -> String {
        guard let tab = browser?.activeTab else { return "" }
        return "<current_page title=\"\(tab.displayTitle)\" url=\"\(tab.url.absoluteString)\" />\n"
    }

    private func runLoop(backend: AssistantBackend, format: AssistantAPIFormat) async {
        var usedBrowser = false
        var handedOff = false
        defer {
            isRunning = false
            if usedBrowser, !handedOff { _ = AgentController.shared.finish() }
        }
        do {
            while true {
                try Task.checkCancellation()
                items.append(.assistant(""))
                let reply = try await backend.send(system: Self.systemPrompt, tools: AssistantTools.definitions, turns: turns)
                dropEmptyAssistantItem()
                turns.append(.assistant(text: reply.text, calls: reply.calls, native: reply.native, format: format))

                switch reply.stop {
                case .refusal:
                    if !reply.calls.isEmpty { close(reply.calls, reason: "Not run.") }
                    items.append(.error("The model declined this request."))
                    return
                case .maxTokens:
                    if !reply.calls.isEmpty { close(reply.calls, reason: "The response was cut off before this ran.") }
                    items.append(.error("The reply hit its length limit."))
                    return
                case .done, .toolUse:
                    break
                }
                guard !reply.calls.isEmpty else { return }

                var outcomes: [AssistantToolOutcome] = []
                for call in reply.calls {
                    if call.inputIsInvalid {
                        outcomes.append(.init(callID: call.id, content: "INVALID_JSON: the tool input did not parse; send it again.", isError: true))
                        continue
                    }
                    items.append(.step(AssistantTools.describe(name: call.name, input: call.input)))
                    usedBrowser = true
                    do {
                        let output = try await AssistantTools.run(name: call.name, input: call.input, browser: browser)
                        outcomes.append(.init(callID: call.id, content: output, isError: false))
                        if call.name == "hand_off_to_user" { handedOff = true }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        outcomes.append(.init(callID: call.id, content: error.localizedDescription, isError: true))
                    }
                }
                turns.append(.toolResults(outcomes))
                if handedOff {
                    items.append(.step("Waiting for you — use “Give back to agent” on the page when you're done, then reply here."))
                    return
                }
            }
        } catch is CancellationError {
            dropEmptyAssistantItem()
            closeDanglingCalls()
            items.append(.step("Stopped."))
        } catch {
            dropEmptyAssistantItem()
            closeDanglingCalls()
            items.append(.error(error.localizedDescription))
        }
    }

    /// Every tool call must be answered before the next turn.
    private func close(_ calls: [AssistantToolCall], reason: String) {
        turns.append(.toolResults(calls.map { .init(callID: $0.id, content: reason, isError: true) }))
    }

    private func closeDanglingCalls() {
        guard case .assistant(_, let calls, _, _) = turns.last, !calls.isEmpty else { return }
        close(calls, reason: "Stopped by the user.")
    }

    private func appendAssistantText(_ text: String) {
        if case .assistant(let current) = items.last {
            items[items.count - 1] = .assistant(current + text)
        } else {
            items.append(.assistant(text))
        }
    }

    private func appendProgress(_ text: String) {
        if case .step(let current) = items.last, !current.hasPrefix("→") {
            items[items.count - 1] = .step(current + text)
        } else {
            dropEmptyAssistantItem()
            items.append(.step(text))
        }
    }

    private func dropEmptyAssistantItem() {
        if case .assistant(let text) = items.last, text.isEmpty { items.removeLast() }
    }

    static let systemPrompt = """
    You are the assistant built into Kylmora, a web browser for macOS. The user is chatting with you in a panel beside the page they are viewing; each of their messages starts with a <current_page> tag naming that page.

    You can read the page and use it like a person would. read_page lists the visible controls with @refs; get_page_text returns the page's readable text. click, type_text, press_key, scroll, navigate and open_tab drive the page with real mouse and keyboard input from a cursor the user can watch.

    - For questions about the page, read it first rather than answering from memory.
    - Take a fresh read_page before acting; refs go stale when the page changes.
    - Never type passwords, payment details or one-time codes, and do not try to solve captchas. When a sign-in, captcha, two-factor or payment step comes up, call hand_off_to_user saying what they need to do, and stop.
    - Ask the user before anything that can't be undone or that others will see: purchases, sending messages, posting, deleting.
    - If a tool says the user is in control, stop and tell them you'll continue when they give control back.
    - Keep replies short and plain. Use Markdown sparingly.
    """
}
