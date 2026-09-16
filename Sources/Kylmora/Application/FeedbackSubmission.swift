import Foundation

/// Posts a report from inside Kylmora to kylmora.com, where it lands in the
/// same table as the website's contact form.
///
/// This is the one place the browser itself talks to our server about
/// anything other than an update check, so it is worth being exact about what
/// that means. It happens when, and only when, someone fills in the Report a
/// Problem sheet and presses Send. There is no queue, no retry in the
/// background, no batching and no event of any kind: close the sheet without
/// sending and nothing has left the Mac. "Kylmora does not phone home" stays
/// true because nothing here happens without a person deciding it should.
///
/// What goes in the request is what is on the screen -- the message they
/// typed, the optional address, and the version, system and Mac model shown to
/// them in the sheet before they pressed Send. No cookies, no identifier, and
/// the request carries no credentials, so two reports from the same Mac cannot
/// be tied together.
enum FeedbackSubmission {
    static let endpoint = URL(string: "https://kylmora.com/api/contact")!

    /// What the user is telling us. Mirrors the kinds the server accepts.
    enum Kind: String, CaseIterable {
        case bug, feature, question, other

        var title: String {
            switch self {
            case .bug: return "Something is broken"
            case .feature: return "A feature idea"
            case .question: return "A question"
            case .other: return "Something else"
            }
        }
    }

    /// A filled-in sheet, ready to send.
    struct Report {
        var kind: Kind = .bug
        var message: String = ""
        /// Optional. Without it we can read the report but not answer it.
        var email: String = ""
        var environment: SupportContact.Environment

        /// The same floor the server enforces, checked here so the Send button
        /// can be disabled rather than the person told off after the fact.
        var isSendable: Bool {
            message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
        }
    }

    enum Outcome: Equatable {
        case sent
        /// Something went wrong and the report is still on screen, unsent.
        case failed(String)
    }

    /// The form body, exactly as the server reads it.
    ///
    /// `source=app` is what separates these from the website's own form once
    /// they are in the table.
    static func formBody(for report: Report) -> String {
        let fields: [(String, String)] = [
            ("source", "app"),
            ("kind", report.kind.rawValue),
            ("message", report.message.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("email", report.email.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("version", "\(report.environment.version) (\(report.environment.build))"),
            ("system", "macOS \(report.environment.system), \(report.environment.model)")
        ]
        return fields
            .filter { !$0.1.isEmpty }
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
    }

    /// `application/x-www-form-urlencoded` escaping, which is not the same as a
    /// URL path's: a space is `+`, and `+`, `&` and `=` must all be encoded or
    /// they change the shape of the body rather than travelling inside it.
    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let percent = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return percent.replacingOccurrences(of: "%20", with: "+")
    }

    static func request(for report: Report) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Named plainly, so anyone watching their own traffic can see exactly
        // what this is rather than finding an unexplained POST.
        request.setValue("Kylmora/\(AppInfo.version) (report a problem)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formBody(for: report).utf8)
        request.timeoutInterval = 20
        return request
    }

    /// Reads the server's answer. The server says `{"ok":true}` or gives a
    /// sentence meant to be shown to the person as-is.
    static func outcome(data: Data?, response: URLResponse?, error: Error?) -> Outcome {
        if let error {
            return .failed("Couldn\u{2019}t reach kylmora.com: \(error.localizedDescription)")
        }
        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(unreachable)
        }
        if payload["ok"] as? Bool == true { return .sent }
        if let message = payload["error"] as? String, !message.isEmpty { return .failed(message) }
        return .failed(unreachable)
    }

    /// Whatever fails, the address is in the answer: a report that cannot be
    /// sent must not be a report that is lost.
    static let unreachable = "That didn\u{2019}t send. You can email \(SupportContact.Address.support) instead \u{2014} it reaches the same person."

    /// Sends it. Nothing is stored, retried or queued: one attempt, one answer.
    ///
    /// An ephemeral session so the request carries no cookies and leaves no
    /// cache behind -- the default session would share the browser's own.
    static func send(_ report: Report) async -> Outcome {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request(for: report))
            return outcome(data: data, response: response, error: nil)
        } catch {
            return outcome(data: nil, response: nil, error: error)
        }
    }
}
