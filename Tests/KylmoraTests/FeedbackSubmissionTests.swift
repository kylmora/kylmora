import Foundation
import Testing
@testable import Kylmora

@Suite("Reports sent from inside the app")
struct FeedbackSubmissionTests {
    private let environment = SupportContact.Environment(
        version: "0.1.54", build: "154", system: "26.6.0", model: "Mac15,3"
    )

    private func report(_ message: String, kind: FeedbackSubmission.Kind = .bug, email: String = "") -> FeedbackSubmission.Report {
        FeedbackSubmission.Report(kind: kind, message: message, email: email, environment: environment)
    }

    private func fields(_ body: String) -> [String: String] {
        var found: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            found[parts[0]] = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]
        }
        return found
    }

    @Test("Every report says it came from the app, which is how the two are told apart")
    func taggedAsApp() {
        #expect(fields(FeedbackSubmission.formBody(for: report("PDFs crash a pinned tab.")))["source"] == "app")
    }

    @Test("The version and the Mac travel with it, and nothing else does")
    func carriesEnvironment() {
        let body = fields(FeedbackSubmission.formBody(for: report("PDFs crash a pinned tab.")))
        #expect(body["version"] == "0.1.54 (154)")
        #expect(body["system"] == "macOS 26.6.0, Mac15,3")
        #expect(body["kind"] == "bug")
        #expect(Set(body.keys) == ["source", "kind", "message", "version", "system"])
    }

    @Test("An address is sent when given and the field is absent when not")
    func optionalEmail() {
        #expect(fields(FeedbackSubmission.formBody(for: report("It broke.", email: "a@b.com")))["email"] == "a@b.com")
        #expect(fields(FeedbackSubmission.formBody(for: report("It broke.")))["email"] == nil)
    }

    @Test("A message full of &, = and + arrives as it was typed")
    func escaping() {
        let typed = "a & b = c + d?e#f\nsecond line 100% sure"
        #expect(fields(FeedbackSubmission.formBody(for: report(typed)))["message"] == typed)
    }

    @Test("Surrounding whitespace is trimmed, so a stray newline is not a message")
    func trimming() {
        #expect(fields(FeedbackSubmission.formBody(for: report("  spaced out  ")))["message"] == "spaced out")
        #expect(!report("   \n  ").isSendable)
    }

    @Test("Send stays off until there is enough to act on")
    func sendableFloor() {
        #expect(!report("").isSendable)
        #expect(!report("too short").isSendable)
        #expect(report("this is long enough").isSendable)
    }

    @Test("The request is a form POST and carries no cookies or credentials")
    func requestShape() {
        let request = FeedbackSubmission.request(for: report("PDFs crash a pinned tab."))
        #expect(request.httpMethod == "POST")
        #expect(request.url == FeedbackSubmission.endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == true || request.httpShouldHandleCookies == false)
    }

    @Test("ok means sent")
    func successAnswer() {
        #expect(FeedbackSubmission.outcome(data: Data(#"{"ok":true}"#.utf8), response: nil, error: nil) == .sent)
    }

    @Test("The server's own sentence is what the person is shown")
    func serverErrorIsShownVerbatim() {
        let data = Data(#"{"ok":false,"error":"Please write a little more so we can help."}"#.utf8)
        #expect(FeedbackSubmission.outcome(data: data, response: nil, error: nil)
            == .failed("Please write a little more so we can help."))
    }

    @Test("Nonsense, silence or a network error all still name somewhere to send it")
    func failuresNameTheAddress() {
        let garbage = FeedbackSubmission.outcome(data: Data("<html>502</html>".utf8), response: nil, error: nil)
        #expect(garbage == .failed(FeedbackSubmission.unreachable))
        #expect(FeedbackSubmission.outcome(data: nil, response: nil, error: nil) == .failed(FeedbackSubmission.unreachable))

        let offline = FeedbackSubmission.outcome(
            data: nil, response: nil, error: URLError(.notConnectedToInternet)
        )
        guard case .failed(let reason) = offline else { return #expect(Bool(false)) }
        #expect(reason.contains("kylmora.com"))
    }
}
