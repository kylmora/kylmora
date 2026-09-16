import AppKit
import Foundation

/// Every way a person can reach us, in one place.
///
/// Kylmora has no telemetry and no crash-reporting service: nothing leaves the
/// Mac on its own, so the only way we ever hear about a bug is that someone
/// tells us. That makes the contact routes a feature rather than a footnote,
/// and it makes them worth writing down once instead of scattering addresses
/// through menus, panes and alerts.
///
/// Mail is composed in the user's own mail client with `mailto:`. Nothing is
/// posted anywhere, the message is theirs until they press Send, and they can
/// read and edit every line of the diagnostics first -- which is the same
/// promise the About pane makes about crash reports.
enum SupportContact {
    /// The addresses, all on kylmora.com. See BRAND_EMAIL.md.
    enum Address {
        /// Something is wrong with the browser.
        static let support = "support@kylmora.com"
        /// Vulnerabilities, handled privately. See SECURITY.md.
        static let security = "security@kylmora.com"
        /// Journalists and reviewers.
        static let press = "press@kylmora.com"
        /// Data and privacy requests.
        static let privacy = "privacy@kylmora.com"
        /// General enquiries, the friendly front door.
        static let hello = "hello@kylmora.com"
    }

    static let contactPage = URL(string: "https://kylmora.com/contact")!
    static let issues = URL(string: "https://github.com/kylmora/kylmora/issues")!
    static let discussions = URL(string: "https://github.com/kylmora/kylmora/discussions")!
    /// GitHub's private advisory form, the route SECURITY.md prefers.
    static let securityAdvisory = URL(string: "https://github.com/kylmora/kylmora/security/advisories/new")!

    // MARK: - What this Mac is

    /// The four facts a bug report needs and nothing more.
    ///
    /// No identifier of any kind: not the serial, not a generated id, not the
    /// hostname, not a single thing that says which Mac this is rather than
    /// what kind. Reproducing a bug needs the version it happened in, the
    /// system it happened on and the shape of the machine; it never needs to
    /// know the machine again later.
    struct Environment: Equatable {
        var version: String
        var build: String
        var system: String
        var model: String

        /// The lines pasted at the foot of a report, ready to read before sending.
        var report: String {
            """
            Kylmora \(version) (\(build))
            macOS \(system)
            Mac \(model)
            """
        }
    }

    /// Reads this Mac. `hw.model` is the marketing-free model identifier
    /// ("Mac15,3"), which says what the hardware is without saying whose.
    static func currentEnvironment() -> Environment {
        Environment(
            version: AppInfo.version,
            build: AppInfo.build,
            system: systemVersion(),
            model: hardwareModel()
        )
    }

    private static func systemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    // MARK: - Composing mail

    /// A `mailto:` URL with the subject and body already filled in.
    ///
    /// Built through `URLComponents` so a newline, an ampersand or a question
    /// mark someone types into a report cannot break out of the query and
    /// truncate their own message.
    static func mailto(to address: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    /// The templates. Each one asks for what we would otherwise have to write
    /// back and ask for, so the first reply can be an answer rather than a
    /// question.
    enum Template {
        case bug, feature, crash(String), question

        var address: String { Address.support }

        func subject(_ environment: Environment) -> String {
            switch self {
            case .bug: return "Bug in Kylmora \(environment.version)"
            case .feature: return "Feature idea for Kylmora"
            case .crash: return "Kylmora \(environment.version) crashed"
            case .question: return "Question about Kylmora \(environment.version)"
            }
        }

        func body(_ environment: Environment) -> String {
            let prompt: String
            switch self {
            case .bug:
                prompt = """
                    What happened:


                    What you expected instead:


                    Steps to reproduce it:
                    1.
                    2.
                    3.

                    Which site, if it is one site:

                    """
            case .feature:
                prompt = """
                    What you would like Kylmora to do:


                    What you are doing when you want it:


                    How you work around it today:

                    """
            case .crash(let report):
                prompt = """
                    What you were doing when it crashed:


                    ---- crash report ----
                    \(report)
                    ---- end of crash report ----

                    """
            case .question:
                prompt = """
                    Your question:

                    """
            }
            return prompt + "\n--\n" + environment.report + "\n"
        }
    }

    /// The finished URL for a template: the body is a draft, editable in the
    /// mail client before a single byte is sent.
    static func url(for template: Template, environment: Environment) -> URL? {
        mailto(to: template.address, subject: template.subject(environment), body: template.body(environment))
    }

    /// The head of a crash report, short enough to survive a `mailto:` URL.
    ///
    /// A whole report is a hundred and twenty frames of backtrace, and a URL
    /// that long is rejected or silently cut by the mail client -- which would
    /// lose the top of the stack, the only part that names the bug. The first
    /// frames are the ones that matter, so those are what goes in the draft,
    /// with a line saying plainly that there is more and where it is.
    static func excerpt(of report: String, maxLines: Int = 40, maxCharacters: Int = 3000) -> String {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var characters = 0
        for line in lines.prefix(maxLines) {
            if characters + line.count + 1 > maxCharacters { break }
            kept.append(line)
            characters += line.count + 1
        }
        let text = kept.joined(separator: "\n")
        guard kept.count < lines.count else { return text }
        return text + "\n[\(lines.count - kept.count) more lines in the saved report]"
    }

    // MARK: - Opening

    /// Hands a template to the user's mail client, or, if the Mac has no mail
    /// client to hand it to, opens the contact page instead.
    ///
    /// A Mac with no account in Mail answers `mailto:` with nothing at all, and
    /// a menu item that does nothing is worse than one that takes you to a page
    /// with the address written on it.
    @MainActor
    @discardableResult
    static func compose(_ template: Template) -> Bool {
        guard let url = url(for: template, environment: currentEnvironment()) else {
            NSWorkspace.shared.open(contactPage)
            return false
        }
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            NSWorkspace.shared.open(contactPage)
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }
}
