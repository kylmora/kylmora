import Foundation
import WebKit

/// Turns a WebKit navigation error into something worth showing a person.
///
/// Pure logic, so which errors surface and what they say are unit tests rather
/// than a judgement made once and forgotten.
struct NavigationFailure: Equatable {
    let title: String
    let message: String
    let isRetryable: Bool

    /// Errors that are not failures at all.
    ///
    /// `NSURLErrorCancelled` fires whenever a load is superseded, which happens
    /// every time someone types a new address mid-load. `frameLoadInterrupted`
    /// is what WebKit reports when a policy decision hands the navigation
    /// elsewhere, such as a link that opens another app. Showing an error page
    /// for either would be wrong.
    static func isSilent(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return true }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return true }
        return false
    }

    init?(_ error: any Error, url: URL?) {
        guard !Self.isSilent(error) else { return nil }
        let error = error as NSError
        let host = url?.host() ?? "this site"

        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            title = "Can't find \(host)"
            message = "The address may be misspelled, or the site may no longer exist."
            isRetryable = true

        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            title = "You're offline"
            message = "Kylmora can't reach the network. Check your connection and try again."
            isRetryable = true

        case (NSURLErrorDomain, NSURLErrorTimedOut):
            title = "\(host) took too long to respond"
            message = "The server may be busy. Trying again often works."
            isRetryable = true

        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            title = "Can't connect to \(host)"
            message = "The server refused the connection, or nothing is listening on that port."
            isRetryable = true

        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot):
            title = "This connection isn't private"
            message = """
                Kylmora could not verify that it is really talking to \(host). \
                Someone may be interfering with the connection.
                """
            // Retrying cannot fix a certificate, and offering the button would
            // suggest the problem is transient.
            isRetryable = false

        case (NSURLErrorDomain, NSURLErrorUnsupportedURL):
            title = "Kylmora can't open this address"
            message = "Nothing on this Mac handles that kind of link."
            isRetryable = false

        default:
            title = "This page didn't load"
            message = error.localizedDescription
            isRetryable = true
        }
    }
}
