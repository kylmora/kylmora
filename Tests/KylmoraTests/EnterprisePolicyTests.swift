import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Enterprise Policies & Corporate Manageability", .serialized)
@MainActor
struct EnterprisePolicyTests {
    init() {
        EnterprisePolicyManager.shared.clearMockPolicies()
    }

    @Test("Enterprise policy keys have titles and summaries")
    func policyKeysMetadata() {
        for key in EnterprisePolicyKey.allCases {
            #expect(!key.rawValue.isEmpty)
            #expect(!key.title.isEmpty)
            #expect(!key.summary.isEmpty)
        }
        #expect(EnterprisePolicyKey.homepageURL.rawValue == "HomepageURL")
        #expect(EnterprisePolicyKey.developerToolsDisabled.rawValue == "DeveloperToolsDisabled")
        #expect(EnterprisePolicyKey.privateBrowsingDisabled.rawValue == "PrivateBrowsingDisabled")
    }

    @Test("Mock policies enable managed state and value resolution")
    func mockPolicyResolution() {
        let manager = EnterprisePolicyManager.shared
        manager.clearMockPolicies()

        manager.setMockPolicies([
            .organizationName: "Kylmora Corp",
            .homepageURL: "https://intranet.example.com",
            .developerToolsDisabled: true,
            .privateBrowsingDisabled: true,
            .passwordManagerDisabled: true,
            .contentBlockingForced: true,
            .autoUpdateForced: true,
            .dohURL: "https://dns.example.com/dns-query",
            .defaultSearchEngine: "duckduckgo",
            .lockSearchEngine: true,
            .urlBlocklist: ["*.gambling.com", "facebook.com", "malware.example.org/*"],
            .urlAllowlist: ["safe.gambling.com"],
            .blockAllExtensions: false,
            .extensionInstallBlocklist: ["bad-extension-1"],
            .extensionInstallAllowlist: ["approved-extension-1"]
        ])

        #expect(manager.isManaged)
        #expect(manager.organizationName == "Kylmora Corp")
        #expect(manager.homepageURL == URL(string: "https://intranet.example.com"))
        #expect(manager.isDeveloperToolsDisabled == true)
        #expect(manager.isPrivateBrowsingDisabled == true)
        #expect(manager.isPasswordManagerDisabled == true)
        #expect(manager.isContentBlockingForced == true)
        #expect(manager.isAutoUpdateForced == true)
        #expect(manager.dohURL == URL(string: "https://dns.example.com/dns-query"))
        #expect(manager.defaultSearchEngine == "duckduckgo")
        #expect(manager.isSearchEngineLocked == true)

        let active = manager.activePolicies
        #expect(active.count >= 10)
        #expect(active.contains { $0.key == .organizationName && $0.valueDescription == "Kylmora Corp" })

        manager.clearMockPolicies()
    }

    @Test("URL pattern matching and blocklist / allowlist logic")
    func urlMatchingAndFiltering() {
        let manager = EnterprisePolicyManager.shared
        manager.setMockPolicies([
            .urlBlocklist: [
                "*.gambling.com",
                "badsite.com",
                "intranet.corp/secret/*",
                "http://*"
            ],
            .urlAllowlist: [
                "allowed.gambling.com",
                "https://intranet.corp/secret/public"
            ]
        ])

        // Internal URLs are always exempt
        #expect(!manager.isURLBlocked(URL(string: "about:blank")!))
        #expect(!manager.isURLBlocked(URL(string: "kylmora://newtab")!))

        // Normal allowed sites
        #expect(!manager.isURLBlocked(URL(string: "https://apple.com")!))
        #expect(!manager.isURLBlocked(URL(string: "https://news.ycombinator.com")!))

        // Blocked domain and subdomain
        #expect(manager.isURLBlocked(URL(string: "https://gambling.com")!))
        #expect(manager.isURLBlocked(URL(string: "https://sub.gambling.com/play")!))
        #expect(manager.isURLBlocked(URL(string: "https://badsite.com")!))
        #expect(manager.isURLBlocked(URL(string: "https://www.badsite.com/foo")!))

        // Allowlist override
        #expect(!manager.isURLBlocked(URL(string: "https://allowed.gambling.com")!))
        #expect(!manager.isURLBlocked(URL(string: "https://allowed.gambling.com/welcome")!))

        // Path-based blocking
        #expect(manager.isURLBlocked(URL(string: "https://intranet.corp/secret/classified")!))
        #expect(!manager.isURLBlocked(URL(string: "https://intranet.corp/secret/public")!))
        #expect(!manager.isURLBlocked(URL(string: "https://intranet.corp/other")!))

        // Scheme wildcard blocking (all http://)
        #expect(manager.isURLBlocked(URL(string: "http://example.org")!))

        manager.clearMockPolicies()
    }

    @Test("Extension install policy filtering")
    func extensionFiltering() {
        let manager = EnterprisePolicyManager.shared

        // 1. Block all extensions
        manager.setMockPolicies([
            .blockAllExtensions: true
        ])
        #expect(!manager.isExtensionAllowed(id: "any-extension"))

        // 2. Allowlist only
        manager.setMockPolicies([
            .extensionInstallAllowlist: ["uBlock0@raymondhill.net", "corporate-helper"]
        ])
        #expect(manager.isExtensionAllowed(id: "uBlock0@raymondhill.net"))
        #expect(manager.isExtensionAllowed(id: "corporate-helper"))
        #expect(!manager.isExtensionAllowed(id: "random-tracker"))

        // 3. Blocklist only
        manager.setMockPolicies([
            .extensionInstallBlocklist: ["unapproved-vpn"]
        ])
        #expect(!manager.isExtensionAllowed(id: "unapproved-vpn"))
        #expect(manager.isExtensionAllowed(id: "anything-else"))

        manager.clearMockPolicies()
    }

    @Test("Settings integration overrides")
    func settingsOverrides() {
        let manager = EnterprisePolicyManager.shared
        manager.setMockPolicies([
            .homepageURL: "https://portal.enterprise.internal",
            .defaultSearchEngine: "duckduckgo",
            .dohURL: "https://1.1.1.1/dns-query"
        ])

        let settings = Settings.shared
        #expect(settings.homepageURL == URL(string: "https://portal.enterprise.internal")!)
        #expect(settings.searchEngine.id == "duckduckgo")
        if case .custom(let url) = settings.dohProvider {
            #expect(url == "https://1.1.1.1/dns-query")
        } else {
            #expect(Bool(false), "Expected DoH provider to be custom with corporate URL")
        }

        manager.clearMockPolicies()
    }

    @Test("Enterprise policies view controller displays items and exports JSON")
    func enterprisePoliciesViewController() throws {
        let manager = EnterprisePolicyManager.shared
        manager.setMockPolicies([
            .organizationName: "Acme Corporation",
            .homepageURL: "https://acme.com",
            .lockSearchEngine: true,
            .developerToolsDisabled: true
        ])

        let controller = EnterprisePoliciesViewController()
        controller.loadView()
        controller.viewDidLoad()

        let displayed = controller.displayedPolicies
        #expect(displayed.count >= 4)
        let dummyTable = NSTableView()
        #expect(controller.numberOfRows(in: dummyTable) >= 4)

        let data = try #require(controller.exportPoliciesData())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("Acme Corporation"))
        #expect(json.contains("acme.com"))
        #expect(json.contains("DeveloperToolsDisabled"))

        manager.clearMockPolicies()
    }
}

@Suite("The Enterprise Policies sheet")
@MainActor
struct EnterprisePoliciesSheetTests {
    @Test("Done closes it however it was opened")
    func doneClosesASheetRunOnAWindow() async {
        // The app menu, the command palette and the Settings spine all run the
        // view in a window of its own as a sheet. Done used to call
        // `dismiss(nil)`, which only knows about a presenting view controller,
        // so on that path it did nothing and a sheet has no close button.
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // Swift owns the windows; AppKit must not free them on close.
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        let controller = EnterprisePoliciesViewController(manager: EnterprisePolicyManager(
            defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        ))
        let sheet = NSWindow(contentViewController: controller)
        sheet.isReleasedWhenClosed = false
        host.beginSheet(sheet) { _ in }
        #expect(host.attachedSheet === sheet)
        controller.cancelOperation(nil)
        #expect(host.attachedSheet == nil, "Escape and Done must end the sheet")
        host.close()
    }

    @Test("An unmanaged Mac is not told it is managed")
    func unmanagedHeaderIsHonest() {
        let manager = EnterprisePolicyManager(
            defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        )
        let controller = EnterprisePoliciesViewController(manager: manager)
        func labels(in view: NSView) -> [String] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0.stringValue] } ?? labels(in: $0) }
        }
        let text = labels(in: controller.view)
        #expect(!manager.isManaged)
        #expect(!text.contains { $0.hasPrefix("Managed by") })
        #expect(text.contains { $0.hasPrefix("Enterprise Policies") })
    }
}

@Suite("The sample enterprise files")
struct EnterpriseSampleFileTests {
    /// The repository root, from this source file.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Every key in the sample policies.json is one the browser knows")
    func sampleJSONKeysExist() throws {
        // The sample is what an administrator copies. A key that drifts from
        // the code is a policy that silently does nothing on their fleet.
        let url = Self.root.appendingPathComponent("Resources/Enterprise/policies.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let known = Set(EnterprisePolicyKey.allCases.map(\.rawValue))
        for key in json.keys {
            #expect(known.contains(key), "\(key) is not an EnterprisePolicyKey")
        }
        #expect(json.count == EnterprisePolicyKey.allCases.count, "the sample should show every policy")
    }

    @Test("The sample profile targets the app's bundle and names only known keys")
    func sampleProfileIsWellFormed() throws {
        let url = Self.root.appendingPathComponent("Resources/Enterprise/Kylmora.mobileconfig")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let payloads = try #require(plist["PayloadContent"] as? [[String: Any]])
        let payload = try #require(payloads.first)
        #expect(payload["PayloadType"] as? String == "com.kylmora.Kylmora")
        let reserved: Set<String> = ["PayloadType", "PayloadIdentifier", "PayloadUUID", "PayloadVersion", "PayloadDisplayName"]
        let known = Set(EnterprisePolicyKey.allCases.map(\.rawValue))
        for key in payload.keys where !reserved.contains(key) {
            #expect(known.contains(key), "\(key) is not an EnterprisePolicyKey")
        }
    }
}
