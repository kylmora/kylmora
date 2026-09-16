import Foundation
import Testing
@testable import Kylmora

@Suite("Getting in touch")
struct SupportContactTests {
    private let environment = SupportContact.Environment(
        version: "0.1.54", build: "154", system: "26.6.0", model: "Mac15,3"
    )

    @Test("Every draft goes to support@ with the version in the subject")
    func addressed() throws {
        for template in [SupportContact.Template.bug, .feature, .question] {
            let url = try #require(SupportContact.url(for: template, environment: environment))
            #expect(url.scheme == "mailto")
            #expect(url.path == "support@kylmora.com")
        }
        #expect(SupportContact.Template.bug.subject(environment) == "Bug in Kylmora 0.1.54")
    }

    @Test("The footer says what Kylmora and the Mac are, and nothing about who")
    func environmentLines() {
        let report = environment.report
        #expect(report == "Kylmora 0.1.54 (154)\nmacOS 26.6.0\nMac Mac15,3")
        // No identifier of any kind ever goes in a draft.
        #expect(!report.lowercased().contains(ProcessInfo.processInfo.hostName.lowercased()))
        #expect(!report.contains(NSUserName()))
    }

    @Test("Every template ends with the environment, whatever it asks first")
    func bodiesCarryEnvironment() {
        for template in [SupportContact.Template.bug, .feature, .question, .crash("SIGSEGV")] {
            #expect(template.body(environment).hasSuffix(environment.report + "\n"))
        }
        #expect(SupportContact.Template.bug.body(environment).contains("Steps to reproduce"))
        #expect(SupportContact.Template.feature.body(environment).contains("What you would like Kylmora to do"))
        #expect(SupportContact.Template.crash("SIGSEGV").body(environment).contains("SIGSEGV"))
    }

    @Test("A body full of & and ? and newlines survives the URL intact")
    func escaping() throws {
        let url = try #require(SupportContact.mailto(
            to: "support@kylmora.com",
            subject: "A & B?",
            body: "line one\nline two & three ?= #four"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.first { $0.name == "subject" }?.value == "A & B?")
        #expect(items.first { $0.name == "body" }?.value == "line one\nline two & three ?= #four")
    }

    @Test("A long crash report is cut to its head, and says how much is left")
    func excerptTruncates() {
        let report = (1...120).map { "frame \($0)" }.joined(separator: "\n")
        let excerpt = SupportContact.excerpt(of: report, maxLines: 10, maxCharacters: 3000)
        #expect(excerpt.hasPrefix("frame 1\n"))
        #expect(excerpt.contains("frame 10"))
        #expect(!excerpt.contains("frame 11\n"))
        #expect(excerpt.contains("[110 more lines in the saved report]"))
    }

    @Test("A report that already fits is left exactly as it is")
    func excerptKeepsShortReports() {
        let report = "Kylmora 0.1.54 crashed\nsignal SIGSEGV\n0 Kylmora 0x1 main"
        #expect(SupportContact.excerpt(of: report) == report)
    }

    @Test("The character budget cuts before the line budget when lines are long")
    func excerptRespectsCharacters() {
        let report = (1...20).map { _ in String(repeating: "x", count: 100) }.joined(separator: "\n")
        let excerpt = SupportContact.excerpt(of: report, maxLines: 20, maxCharacters: 250)
        #expect(excerpt.split(separator: "\n").count == 3)  // two lines plus the "more" note
        #expect(excerpt.contains("[18 more lines in the saved report]"))
    }

    @Test("This Mac answers with a version, a system and a model")
    func currentEnvironmentIsFilledIn() {
        let now = SupportContact.currentEnvironment()
        #expect(!now.system.isEmpty)
        #expect(now.model != "unknown")
        #expect(now.report.contains("macOS "))
    }
}
