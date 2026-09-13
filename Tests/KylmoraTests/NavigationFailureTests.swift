import Foundation
import Testing
@testable import Kylmora

private func urlError(_ code: Int) -> NSError {
    NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "described"])
}

@Suite("Navigation failures")
struct NavigationFailureTests {
    private let site = URL(string: "https://example.com/page")!

    @Test("A superseded load is not an error the user should see")
    func cancelledIsSilent() {
        #expect(NavigationFailure.isSilent(urlError(NSURLErrorCancelled)))
        #expect(NavigationFailure(urlError(NSURLErrorCancelled), url: site) == nil)
    }

    @Test("A navigation handed off by policy is not an error either")
    func frameLoadInterruptedIsSilent() {
        let error = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(NavigationFailure.isSilent(error))
        #expect(NavigationFailure(error, url: site) == nil)
    }

    @Test("A real failure names the host it could not reach")
    func hostIsNamed() {
        let failure = NavigationFailure(urlError(NSURLErrorCannotFindHost), url: site)
        #expect(failure?.title.contains("example.com") == true)
        #expect(failure?.isRetryable == true)
    }

    @Test("Being offline is reported as being offline")
    func offline() {
        let failure = NavigationFailure(urlError(NSURLErrorNotConnectedToInternet), url: site)
        #expect(failure?.title == "You're offline")
        #expect(failure?.isRetryable == true)
    }

    @Test("A certificate problem offers no retry, because retrying cannot fix it", arguments: [
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorServerCertificateHasUnknownRoot
    ])
    func certificateFailures(code: Int) {
        let failure = NavigationFailure(urlError(code), url: site)
        #expect(failure?.isRetryable == false)
        #expect(failure?.title == "This connection isn't private")
    }

    @Test("An unknown failure falls back to the system description")
    func unknownFailure() {
        let failure = NavigationFailure(urlError(NSURLErrorUnknown), url: site)
        #expect(failure?.message == "described")
        #expect(failure?.isRetryable == true)
    }

    @Test("A missing URL still produces a usable message")
    func noURL() {
        let failure = NavigationFailure(urlError(NSURLErrorCannotFindHost), url: nil)
        #expect(failure?.title.contains("this site") == true)
    }
}

@Suite("Tab failure state")
@MainActor
struct TabFailureTests {
    @Test("A fresh tab has no failure")
    func noFailureInitially() {
        let tab = Tab(url: URL(string: "https://example.com")!, identity: .standard)
        #expect(tab.failure == nil)
    }

    @Test("Suspending a tab clears its failure, so it retries when reopened")
    func unloadClearsFailure() {
        let tab = Tab(url: URL(string: "https://example.com")!, identity: .standard)
        tab.unload()
        #expect(tab.failure == nil)
    }
}
