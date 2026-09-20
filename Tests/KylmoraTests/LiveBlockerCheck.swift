import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

/// A check against a real extension, run by hand rather than in CI: point
/// `KYLMORA_LIVE_EXTENSION` at an unpacked extension folder and it reads that
/// extension's own rules, translates them and makes WebKit enforce them.
@Suite("Live blocker check")
@MainActor
struct LiveBlockerCheck {
    private var folder: URL? {
        ProcessInfo.processInfo.environment["KYLMORA_LIVE_EXTENSION"].map { URL(filePath: $0) }
    }

    @Test("A real MV3 blocker's own rules translate and compile")
    func realExtension() async throws {
        guard let folder else { return }
        let defaults = UserDefaults(suiteName: "kylmora-live-\(UUID().uuidString)")!
        let service = DeclarativeNetRequestService(defaults: defaults)
        let id = UUID()
        let started = Date()
        await service.load(recordID: id, folder: folder)
        let entry = try #require(service.entries[id])
        let read = service.allRules(for: id)
        let compilation = DeclarativeNetRequestCompiler.compile(read.rules)

        print("LIVE: rulesets=\(entry.definition.rulesets.count) enabled=\(entry.enabledRulesets.count)")
        print("LIVE: rules read=\(read.rules.count) rejected=\(read.rejected.count)")
        print("LIVE: translated=\(compilation.translated) unsupported=\(compilation.unsupported.count) navigationOnly=\(compilation.navigationOnly.count)")
        var reasons: [String: Int] = [:]
        for item in compilation.unsupported { reasons[item.reason, default: 0] += 1 }
        for (reason, count) in reasons.sorted(by: { $0.value > $1.value }).prefix(8) {
            print("LIVE:   \(count) x \(reason)")
        }
        print("LIVE: compiled=\(entry.compiled != nil) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        #expect(entry.compiled != nil, "WebKit holds a compiled list for a real blocker")
        #expect(compilation.translated > 1000, "a real blocker contributes a real number of rules")
    }

    @Test("The real blocker's rules, enforced by WebKit, actually stop a request")
    func realExtensionBlocksForReal() async throws {
        guard let folder else { return }
        let defaults = UserDefaults(suiteName: "kylmora-live-\(UUID().uuidString)")!
        let service = DeclarativeNetRequestService(defaults: defaults)
        let id = UUID()
        await service.load(recordID: id, folder: folder)
        let lists = service.ruleLists(for: .standard)
        #expect(!lists.isEmpty)

        let configuration = WKWebViewConfiguration()
        for list in lists { configuration.userContentController.add(list) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView!.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "http://localhost:8765/index.html")!))
        for _ in 0..<400 where webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }

        // Two fetches from the same local server. One path matches a rule the
        // extension actually ships; the other does not. Both exist and both
        // return 200 to curl, so a difference here is the blocker working.
        _ = try await webView.evaluateJavaScript("""
        window.__result = null;
        Promise.all([
          fetch('/media/player/videojs/videojs.ads.min.js').then(r => 'ads:' + r.status, () => 'ads:blocked'),
          fetch('/app.js').then(r => 'app:' + r.status, () => 'app:blocked')
        ]).then(v => { window.__result = v.join(' '); });
        true;
        """)
        var result: String?
        for _ in 0..<200 {
            if let value = try? await webView.evaluateJavaScript("window.__result") as? String {
                result = value
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let answer = try #require(result)
        print("LIVE: fetches -> \(answer)")
        #expect(answer.contains("ads:blocked"), "a path the extension's own rules name must not load")
        #expect(answer.contains("app:200"), "everything else must still load")
    }

    @Test("Compiling a real blocker is paid once, not on every launch")
    func compilationIsCached() async throws {
        guard let folder else { return }
        let defaults = UserDefaults(suiteName: "kylmora-live-\(UUID().uuidString)")!
        let id = UUID()

        let first = Date()
        let one = DeclarativeNetRequestService(defaults: defaults)
        await one.load(recordID: id, folder: folder)
        let firstTime = Date().timeIntervalSince(first)

        // The next launch: same extension, same rules, same identifier.
        let second = Date()
        let two = DeclarativeNetRequestService(defaults: defaults)
        await two.load(recordID: id, folder: folder)
        let secondTime = Date().timeIntervalSince(second)

        print("LIVE: first compile \(Int(firstTime * 1000))ms, second \(Int(secondTime * 1000))ms")
        #expect(two.entries[id]?.compiled != nil)
        #expect(secondTime < firstTime / 2, "the second load reuses what WebKit already holds")
    }
}
