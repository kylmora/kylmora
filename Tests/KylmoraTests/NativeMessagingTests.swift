import Foundation
import Testing
@testable import Kylmora

/// Native messaging, tested against real programs.
///
/// Nothing here is a stand-in. Every test writes a host manifest to disk and a
/// program next to it, then makes Kylmora start that program and talk to it
/// over real pipes. A test that passes means a real process read Kylmora's
/// bytes and Kylmora read the bytes it wrote back, which is the only evidence
/// worth having for a protocol whose whole surface is another process.
private enum Bench {
    /// A fresh folder for one test.
    static func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "kylmora.native-messaging.\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a runnable program and returns where it is.
    @discardableResult
    static func program(_ body: String, named name: String, in folder: URL) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    /// Writes a manifest and returns where it is.
    @discardableResult
    static func manifest(name: String,
                         path: String,
                         in folder: URL,
                         origins: [String] = ["chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/"],
                         extensions: [String]? = nil,
                         type: String = "stdio",
                         fileName: String? = nil) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var json: [String: Any] = [
            "name": name,
            "description": "A host that exists only for this test",
            "path": path,
            "type": type,
        ]
        if let extensions {
            json["allowed_extensions"] = extensions
        } else {
            json["allowed_origins"] = origins
        }
        let url = folder.appending(path: (fileName ?? name) + ".json")
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try? data.write(to: url)
        return url
    }

    static func directory(_ url: URL, label: String = "Kylmora", own: Bool = true, gecko: Bool = false) -> NativeMessagingDirectory {
        NativeMessagingDirectory(label: label, url: url, isOwn: own, usesGeckoIdentifiers: gecko)
    }

    static let identity = NativeMessagingExtensionIdentity(
        displayName: "Test Extension",
        origins: ["chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/"],
        geckoIdentifiers: ["test@kylmora.example"]
    )

    /// The preamble every Python host here shares: read and write the
    /// length-prefixed JSON Chrome defined.
    static let pythonPreamble = """
    #!/usr/bin/env python3
    import sys, struct, json, os, time

    def read_message():
        raw = sys.stdin.buffer.read(4)
        if len(raw) < 4:
            return None
        length = struct.unpack('<I', raw)[0]
        body = sys.stdin.buffer.read(length)
        if len(body) < length:
            return None
        return json.loads(body.decode('utf-8'))

    def write_message(value):
        body = json.dumps(value).encode('utf-8')
        sys.stdout.buffer.write(struct.pack('<I', len(body)))
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()

    """

    /// Whether a process whose command line contains `marker` is running.
    /// Used to prove a host really was stopped, not merely forgotten.
    static func isRunning(marker: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", marker]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Makes the manifest, the program, and the host record for it, all in one
    /// folder named after the host.
    static func host(named name: String,
                     program body: String,
                     origins: [String] = ["chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/"],
                     extensions: [String]? = nil,
                     gecko: Bool = false,
                     programName: String? = nil,
                     in root: URL) throws -> NativeMessagingHost {
        // The program's own file name is what shows up in the process list,
        // which is how a test can tell whether it is still running.
        let executable = program(body, named: programName ?? "\(name).py", in: root)
        let manifestURL = manifest(name: name, path: executable.path(percentEncoded: false), in: root,
                                   origins: origins, extensions: extensions)
        return try NativeMessagingHost.read(manifestURL, in: directory(root, gecko: gecko))
    }
}

// MARK: - The wire format

@Suite("Native messaging speaks Chrome's wire format")
struct NativeMessagingFramingTests {
    @Test("A message is four little-endian length bytes and then the JSON")
    func framing() throws {
        let payload = Data("{\"a\":1}".utf8)
        let frame = try NativeMessagingFraming.frame(payload)
        #expect(frame.count == payload.count + 4)
        #expect(Array(frame.prefix(4)) == [7, 0, 0, 0])
        #expect(frame.dropFirst(4) == payload)
    }

    @Test("A message that arrives in pieces is put back together")
    func reassembly() throws {
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let frame = try NativeMessagingFraming.frame(payload)
        var reader = NativeMessagingFraming.Reader()
        var messages: [Data] = []
        // One byte at a time: the cruellest split a pipe can hand over.
        for byte in frame {
            messages += try reader.append(Data([byte]))
        }
        #expect(messages == [payload])
        #expect(reader.pendingByteCount == 0)
    }

    @Test("Several messages in one read all come out, in order")
    func batched() throws {
        var lump = Data()
        let payloads = [Data("1".utf8), Data("22".utf8), Data("333".utf8)]
        for payload in payloads {
            lump.append(try NativeMessagingFraming.frame(payload))
        }
        var reader = NativeMessagingFraming.Reader()
        #expect(try reader.append(lump) == payloads)
    }

    @Test("Half a message is held back until the rest arrives")
    func partial() throws {
        let payload = Data("abcdefgh".utf8)
        let frame = try NativeMessagingFraming.frame(payload)
        var reader = NativeMessagingFraming.Reader()
        #expect(try reader.append(frame.prefix(6)) == [])
        #expect(reader.pendingByteCount == 6)
        #expect(try reader.append(frame.dropFirst(6)) == [payload])
    }

    @Test("A length past the limit is refused rather than allocated")
    func oversizeAnnouncement() {
        var reader = NativeMessagingFraming.Reader()
        var frame = Data([0xFF, 0xFF, 0xFF, 0xFF])
        frame.append(Data("x".utf8))
        #expect(throws: NativeMessagingFraming.Failure.messageTooLarge(Int(UInt32.max))) {
            _ = try reader.append(frame)
        }
    }

    @Test("A message too large to send is refused before it is written")
    func oversizeSend() {
        #expect(throws: (any Error).self) {
            _ = try NativeMessagingFraming.frame(Data(count: NativeMessagingFraming.maximumMessageBytes + 1))
        }
    }

    @Test("JSON that is not an object is still a message", arguments: [
        "\"just a string\"", "42", "true", "null", "[1,2,3]",
    ])
    func fragments(_ json: String) throws {
        let value = try NativeMessagingFraming.message(from: Data(json.utf8))
        let round = try NativeMessagingFraming.data(from: value)
        #expect(String(decoding: round, as: UTF8.self) == json)
    }

    @Test("A message that is not JSON at all is refused")
    func notSerializable() {
        #expect(throws: NativeMessagingFraming.Failure.notSerializable) {
            _ = try NativeMessagingFraming.data(from: Date())
        }
    }

    @Test("Keys are written in the same order every time")
    func stableKeys() throws {
        let data = try NativeMessagingFraming.data(from: ["b": 1, "a": 2, "c": 3] as [String: Any])
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":2,"b":1,"c":3}"#)
    }
}

// MARK: - Reading manifests

@Suite("A host manifest is read the way Chrome reads one")
struct NativeMessagingManifestTests {
    @Test("A well-formed manifest names a program Kylmora may run")
    func valid() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.good", program: "#!/bin/sh\nexit 0\n", in: root)
        #expect(host.name == "com.example.good")
        #expect(host.summary == "A host that exists only for this test")
        #expect(host.executable.lastPathComponent == "com.example.good.py")
        #expect(host.allowedOrigins == ["chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/"])
    }

    @Test("A path relative to the manifest resolves beside it")
    func relativePath() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        Bench.program("#!/bin/sh\nexit 0\n", named: "helper", in: root)
        let manifestURL = Bench.manifest(name: "com.example.relative", path: "helper", in: root)
        let host = try NativeMessagingHost.read(manifestURL, in: Bench.directory(root))
        #expect(host.executable == root.appending(path: "helper").resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("A manifest that calls itself something else than its file is refused")
    func nameMismatch() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let executable = Bench.program("#!/bin/sh\nexit 0\n", named: "p", in: root)
        let manifestURL = Bench.manifest(name: "com.example.real", path: executable.path(percentEncoded: false),
                                         in: root, fileName: "com.example.pretender")
        #expect(throws: NativeMessagingHost.Failure.nameMismatch(claimed: "com.example.real", file: "com.example.pretender")) {
            _ = try NativeMessagingHost.read(manifestURL, in: Bench.directory(root))
        }
    }

    @Test("A host asking for a protocol Kylmora does not speak is refused")
    func unsupportedType() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let executable = Bench.program("#!/bin/sh\nexit 0\n", named: "p", in: root)
        let manifestURL = Bench.manifest(name: "com.example.web", path: executable.path(percentEncoded: false),
                                         in: root, type: "native_messaging_host_v2")
        #expect(throws: NativeMessagingHost.Failure.unsupportedType("native_messaging_host_v2")) {
            _ = try NativeMessagingHost.read(manifestURL, in: Bench.directory(root))
        }
    }

    @Test("A manifest pointing at nothing is refused")
    func missingExecutable() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let manifestURL = Bench.manifest(name: "com.example.gone", path: root.appending(path: "nowhere").path(percentEncoded: false), in: root)
        #expect(throws: (any Error).self) {
            _ = try NativeMessagingHost.read(manifestURL, in: Bench.directory(root))
        }
    }

    @Test("A file nobody may run is refused")
    func notExecutable() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let executable = Bench.program("#!/bin/sh\nexit 0\n", named: "p", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path(percentEncoded: false))
        let manifestURL = Bench.manifest(name: "com.example.unrunnable", path: executable.path(percentEncoded: false), in: root)
        #expect(throws: NativeMessagingHost.Failure.executableNotRunnable(executable.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false))) {
            _ = try NativeMessagingHost.read(manifestURL, in: Bench.directory(root))
        }
    }

    @Test("A program anyone on the Mac can rewrite is refused")
    func worldWritable() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let executable = Bench.program("#!/bin/sh\nexit 0\n", named: "p", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: executable.path(percentEncoded: false))
        let manifestURL = Bench.manifest(name: "com.example.writable", path: executable.path(percentEncoded: false), in: root)
        #expect(throws: NativeMessagingHost.Failure.executableWorldWritable(executable.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false))) {
            _ = try NativeMessagingHost.read(manifestURL, in: Bench.directory(root))
        }
    }

    @Test("A file that is not a manifest at all is refused")
    func malformed() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let url = root.appending(path: "com.example.junk.json")
        try Data("not json".utf8).write(to: url)
        #expect(throws: NativeMessagingHost.Failure.malformed) {
            _ = try NativeMessagingHost.read(url, in: Bench.directory(root))
        }
    }

    @Test("A name that could be a path is not a name", arguments: [
        "../../etc/passwd", "com.example/../other", "com example", "", "com.example.", ".com.example", "com..example",
    ])
    func invalidNames(_ name: String) {
        #expect(!NativeMessagingHost.isValidName(name))
    }

    @Test("The names real hosts use are accepted", arguments: [
        "com.8bit.bitwarden", "com.apple.passwordmanager", "com_1password_browser_helper", "host1",
    ])
    func validNames(_ name: String) {
        #expect(NativeMessagingHost.isValidName(name))
    }

    @Test("A host's allow-list decides who may reach it")
    func allowList() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.picky", program: "#!/bin/sh\nexit 0\n", in: root)
        #expect(host.allows(Bench.identity))
        let stranger = NativeMessagingExtensionIdentity(
            displayName: "Somebody else",
            origins: ["chrome-extension://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/"],
            geckoIdentifiers: []
        )
        #expect(!host.allows(stranger))
    }

    @Test("A Firefox manifest names add-ons instead of origins")
    func geckoAllowList() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.gecko", program: "#!/bin/sh\nexit 0\n",
                                  extensions: ["test@kylmora.example"], gecko: true, in: root)
        #expect(host.allowedExtensionIDs == ["test@kylmora.example"])
        #expect(host.allows(Bench.identity))
        let stranger = NativeMessagingExtensionIdentity(displayName: "x", origins: [], geckoIdentifiers: ["other@example.com"])
        #expect(!host.allows(stranger))
    }
}

// MARK: - Finding hosts

@Suite("Hosts are found where browsers keep them")
struct NativeMessagingRegistryTests {
    @Test("Every manifest in a folder is found")
    func scans() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.one", program: "#!/bin/sh\nexit 0\n", in: root)
        _ = try Bench.host(named: "com.example.two", program: "#!/bin/sh\nexit 0\n", in: root)
        let registry = NativeMessagingHostRegistry(directories: [Bench.directory(root)])
        let scan = await registry.scan()
        #expect(scan.hosts.map(\.name) == ["com.example.one", "com.example.two"])
    }

    @Test("Kylmora's own folder wins over a browser's")
    func ownFolderFirst() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let mine = root.appending(path: "kylmora", directoryHint: .isDirectory)
        let theirs = root.appending(path: "chrome", directoryHint: .isDirectory)
        _ = try Bench.host(named: "com.example.shared", program: "#!/bin/sh\nexit 0\n", in: mine)
        _ = try Bench.host(named: "com.example.shared", program: "#!/bin/sh\nexit 1\n", in: theirs)
        let registry = NativeMessagingHostRegistry(directories: [
            Bench.directory(mine),
            Bench.directory(theirs, label: "Google Chrome", own: false),
        ])
        let scan = await registry.scan()
        #expect(scan.hosts.count == 1)
        #expect(scan.hosts.first?.directory.label == "Kylmora")
    }

    @Test("Other browsers' hosts can be left out")
    func withoutOtherBrowsers() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let mine = root.appending(path: "kylmora", directoryHint: .isDirectory)
        let theirs = root.appending(path: "chrome", directoryHint: .isDirectory)
        _ = try Bench.host(named: "com.example.mine", program: "#!/bin/sh\nexit 0\n", in: mine)
        _ = try Bench.host(named: "com.example.theirs", program: "#!/bin/sh\nexit 0\n", in: theirs)
        let registry = NativeMessagingHostRegistry(directories: [
            Bench.directory(mine),
            Bench.directory(theirs, label: "Google Chrome", own: false),
        ])
        let all = await registry.scan()
        #expect(all.hosts.count == 2)
        let ownOnly = await registry.scan(includingOtherBrowsers: false)
        #expect(ownOnly.hosts.map(\.name) == ["com.example.mine"])
    }

    @Test("A manifest that will not load is reported, not silently dropped")
    func rejections() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        try Data("{".utf8).write(to: root.appending(path: "com.example.broken.json"))
        let registry = NativeMessagingHostRegistry(directories: [Bench.directory(root)])
        let scan = await registry.scan()
        #expect(scan.hosts.isEmpty)
        #expect(scan.rejections.count == 1)
        #expect(scan.rejections.first?.reason.contains("not a native messaging manifest") == true)
    }

    @Test("A host installed after the first look is still found")
    func rescans() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let registry = NativeMessagingHostRegistry(directories: [Bench.directory(root)])
        #expect(await registry.scan().hosts.isEmpty)
        _ = try Bench.host(named: "com.example.late", program: "#!/bin/sh\nexit 0\n", in: root)
        let found = await registry.host(named: "com.example.late")
        #expect(found?.name == "com.example.late")
    }

    @Test("A missing folder is not an error")
    func missingDirectory() async {
        let root = Bench.makeRoot()
        Bench.remove(root)
        let registry = NativeMessagingHostRegistry(directories: [Bench.directory(root)])
        let scan = await registry.scan()
        #expect(scan.hosts.isEmpty)
        #expect(scan.rejections.isEmpty)
    }

    @Test("The folders searched are the ones browsers actually use")
    func standardDirectories() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let directories = NativeMessagingDirectory.standard(home: home)
        let paths = directories.map { $0.url.standardizedFileURL.path(percentEncoded: false) }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        #expect(paths.first == "/Users/someone/Library/Application Support/Kylmora/NativeMessagingHosts")
        #expect(paths.contains("/Users/someone/Library/Application Support/Google/Chrome/NativeMessagingHosts"))
        #expect(paths.contains("/Library/Google/Chrome/NativeMessagingHosts"))
        #expect(paths.contains("/Users/someone/Library/Application Support/Mozilla/NativeMessagingHosts"))
        #expect(paths.contains("/Users/someone/Library/Application Support/com.kylmora.Kylmora/NativeMessagingHosts"))
        // Kylmora's own folders are searched before anyone else's.
        #expect(directories.prefix(4).allSatisfy { $0.isOwn })
        #expect(directories.filter(\.isOwn).count == 4)
        #expect(directories.filter(\.usesGeckoIdentifiers).allSatisfy { $0.label.hasPrefix("Firefox") })
    }
}

// MARK: - Who an extension is

@Suite("An extension is recognised the way a host's manifest names it")
struct NativeMessagingIdentityTests {
    /// A fixed key and the identifier Chrome derives from it, worked out
    /// independently of the code under test. If the mapping ever drifts, every
    /// real host manifest stops recognising extensions installed from a file,
    /// so it is worth a vector rather than a round trip.
    @Test("Chrome's identifier is derived from the extension's own key")
    func chromeIdentifier() {
        let key = Data("kylmora native messaging test key".utf8)
        #expect(NativeMessagingIdentity.chromeIdentifier(forKeyBytes: key) == "fldohinlnnfloaogkmokhgjjkmmdbbbo")
    }

    @Test("An identifier is always thirty-two letters between a and p")
    func identifierShape() {
        for length in [1, 32, 294] {
            let identifier = NativeMessagingIdentity.chromeIdentifier(forKeyBytes: Data(repeating: 7, count: length))
            #expect(identifier.count == 32)
            #expect(identifier.allSatisfy { $0 >= "a" && $0 <= "p" })
        }
    }

    @Test("A key that is not base64 yields no identifier")
    func badKey() {
        #expect(NativeMessagingIdentity.chromeIdentifier(forPackedKey: "") == nil)
    }

    @Test("A store-installed extension claims its store identifier")
    func storeIdentity() {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let record = InstalledExtension(id: UUID(), name: "Bitwarden", version: "1", isEnabled: true,
                                        installedAt: .now, storeID: "nngceckbapebfimnlniiiahkandclblb")
        let identity = NativeMessagingIdentity.identity(for: record, folder: root, engineIdentifier: record.id.uuidString)
        #expect(identity.origins.contains("chrome-extension://nngceckbapebfimnlniiiahkandclblb/"))
        #expect(identity.origins.contains("chrome-extension://\(record.id.uuidString.lowercased())/"))
        #expect(identity.displayName == "Bitwarden")
    }

    @Test("An extension installed from a file claims the identifier its own key gives it")
    func packedKeyIdentity() throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let key = Data("kylmora native messaging test key".utf8).base64EncodedString()
        let manifest: [String: Any] = ["name": "Packed", "version": "1", "key": key]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appending(path: "manifest.json"))
        let record = InstalledExtension(id: UUID(), name: "Packed", version: "1", isEnabled: true, installedAt: .now)
        let identity = NativeMessagingIdentity.identity(for: record, folder: root, engineIdentifier: record.id.uuidString)
        #expect(identity.origins.contains("chrome-extension://fldohinlnnfloaogkmokhgjjkmmdbbbo/"))
    }

    @Test("A Firefox add-on claims the identifier its manifest declares", arguments: [
        "browser_specific_settings", "applications",
    ])
    func geckoIdentity(_ key: String) throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let manifest: [String: Any] = [
            "name": "Gecko", "version": "1",
            key: ["gecko": ["id": "addon@kylmora.example"]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appending(path: "manifest.json"))
        let record = InstalledExtension(id: UUID(), name: "Gecko", version: "1", isEnabled: true, installedAt: .now)
        let identity = NativeMessagingIdentity.identity(for: record, folder: root, engineIdentifier: record.id.uuidString)
        #expect(identity.geckoIdentifiers.contains("addon@kylmora.example"))
    }

    @Test("An extension cannot claim an identifier it has no evidence for")
    func noForgery() {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let record = InstalledExtension(id: UUID(), name: "Nobody", version: "1", isEnabled: true, installedAt: .now)
        let identity = NativeMessagingIdentity.identity(for: record, folder: root, engineIdentifier: record.id.uuidString)
        #expect(identity.origins == ["chrome-extension://\(record.id.uuidString.lowercased())/"])
        #expect(identity.geckoIdentifiers.isEmpty)
    }
}

// MARK: - Real conversations with real programs

@Suite("Kylmora holds a real conversation with a real program", .serialized)
struct NativeMessagingConversationTests {
    private static let echo = Bench.pythonPreamble + """
    while True:
        message = read_message()
        if message is None:
            break
        write_message({"echo": message})
    """

    @Test("A message goes out and the host's answer comes back")
    func roundTrip() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.echo", program: Self.echo, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        let payload = try NativeMessagingFraming.data(from: ["hello": "kylmora"])
        let reply = try await connection.request(payload, timeout: .seconds(10))
        let value = try NativeMessagingFraming.message(from: reply) as? [String: Any]
        #expect((value?["echo"] as? [String: Any])?["hello"] as? String == "kylmora")
        await connection.close()
    }

    @Test("A conversation carries on, both ways, for as long as both sides want")
    func persistentConversation() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.chat", program: Self.echo, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        for index in 1...25 {
            let payload = try NativeMessagingFraming.data(from: ["n": index])
            let reply = try await connection.request(payload, timeout: .seconds(10))
            let value = try NativeMessagingFraming.message(from: reply) as? [String: Any]
            #expect((value?["echo"] as? [String: Any])?["n"] as? Int == index)
        }
        await connection.close()
    }

    @Test("A host that speaks first is heard")
    func hostSpeaksFirst() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let greeter = Bench.pythonPreamble + """
        for i in range(3):
            write_message({"greeting": i})
        time.sleep(30)
        """
        let host = try Bench.host(named: "com.example.greeter", program: greeter, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        var greetings: [Int] = []
        for _ in 0..<3 {
            let data = try await connection.nextMessage()
            let value = try NativeMessagingFraming.message(from: data) as? [String: Any]
            greetings.append(value?["greeting"] as? Int ?? -1)
        }
        // Order is the protocol's only guarantee, and it must hold.
        #expect(greetings == [0, 1, 2])
        await connection.close()
    }

    @Test("A message far larger than a pipe's buffer survives the trip")
    func largeMessage() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.big", program: Self.echo, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        // 4 MB, sixty-four times what a pipe holds at once, so both the write
        // and the read have to deal with being interrupted part-way.
        let body = String(repeating: "kylmora", count: 600_000)
        let payload = try NativeMessagingFraming.data(from: ["body": body])
        #expect(payload.count > 4_000_000)
        let reply = try await connection.request(payload, timeout: .seconds(30))
        let value = try NativeMessagingFraming.message(from: reply) as? [String: Any]
        #expect((value?["echo"] as? [String: Any])?["body"] as? String == body)
        await connection.close()
    }

    @Test("The host is told who is calling, the way Chrome tells it")
    func chromeArguments() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let reporter = Bench.pythonPreamble + """
        write_message({"argv": sys.argv[1:], "cwd": os.getcwd()})
        time.sleep(30)
        """
        let host = try Bench.host(named: "com.example.argv", program: reporter, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        let value = try NativeMessagingFraming.message(from: try await connection.nextMessage()) as? [String: Any]
        #expect(value?["argv"] as? [String] == ["chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/"])
        // Started beside itself, not wherever Kylmora happened to be.
        #expect((value?["cwd"] as? String)?.hasSuffix(root.lastPathComponent) == true)
        await connection.close()
    }

    @Test("A Firefox host is told what Firefox tells it")
    func firefoxArguments() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let reporter = Bench.pythonPreamble + """
        write_message({"argv": sys.argv[1:]})
        time.sleep(30)
        """
        let host = try Bench.host(named: "com.example.gecko.argv", program: reporter,
                                  extensions: ["test@kylmora.example"], gecko: true, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        let value = try NativeMessagingFraming.message(from: try await connection.nextMessage()) as? [String: Any]
        let argv = value?["argv"] as? [String] ?? []
        #expect(argv.count == 2)
        #expect(argv.first?.hasSuffix("com.example.gecko.argv.json") == true)
        #expect(argv.last == "test@kylmora.example")
        await connection.close()
    }

    @Test("A host that dies says so instead of hanging")
    func hostDies() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let quitter = Bench.pythonPreamble + """
        sys.exit(3)
        """
        let host = try Bench.host(named: "com.example.quitter", program: quitter, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        await #expect(throws: (any Error).self) {
            _ = try await connection.request(try NativeMessagingFraming.data(from: ["x": 1]), timeout: .seconds(10))
        }
        await connection.close()
    }

    @Test("What a failing host wrote to standard error is kept for the user")
    func diagnostics() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let complainer = Bench.pythonPreamble + """
        sys.stderr.write("vault is locked\\n")
        sys.stderr.flush()
        sys.exit(1)
        """
        let host = try Bench.host(named: "com.example.complainer", program: complainer, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        do {
            _ = try await connection.request(try NativeMessagingFraming.data(from: ["x": 1]), timeout: .seconds(10))
            Issue.record("A host that exited should not have answered")
        } catch let failure as NativeMessagingConnection.Failure {
            #expect(failure.detail.contains("vault is locked"))
            #expect(failure.chromeMessage == "Native host has exited.")
        }
        await connection.close()
    }

    @Test("A host that announces a message it cannot fill is cut off")
    func lyingLength() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let liar = Bench.pythonPreamble + """
        sys.stdout.buffer.write(struct.pack('<I', 4000000000))
        sys.stdout.buffer.write(b'{}')
        sys.stdout.buffer.flush()
        time.sleep(30)
        """
        let host = try Bench.host(named: "com.example.liar", program: liar, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        do {
            _ = try await connection.nextMessage()
            Issue.record("A frame that large should have ended the connection")
        } catch let failure as NativeMessagingConnection.Failure {
            guard case .badFrame = failure else {
                Issue.record("Expected a bad frame, got \(failure)")
                return
            }
        }
        #expect(await connection.isOpen == false)
        await connection.close()
    }

    @Test("A host writing something that is not JSON is cut off")
    func notJSON() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let babbler = Bench.pythonPreamble + """
        body = b'this is not json'
        sys.stdout.buffer.write(struct.pack('<I', len(body)))
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()
        time.sleep(30)
        """
        let host = try Bench.host(named: "com.example.babbler", program: babbler, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        await #expect(throws: (any Error).self) {
            _ = try await connection.nextMessage()
        }
        await connection.close()
    }

    @Test("A host that never answers is given up on")
    func timeout() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let silent = Bench.pythonPreamble + """
        time.sleep(60)
        """
        let host = try Bench.host(named: "com.example.silent", program: silent, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        let started = Date()
        do {
            _ = try await connection.request(try NativeMessagingFraming.data(from: ["x": 1]), timeout: .milliseconds(600))
            Issue.record("A silent host should not have answered")
        } catch let failure as NativeMessagingConnection.Failure {
            #expect(failure == .timedOut)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        await connection.close()
    }

    @Test("Closing the connection really stops the program")
    func closeStopsTheProgram() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let marker = "kylmora-close-\(UUID().uuidString)"
        let sleeper = Bench.pythonPreamble + """
        # \(marker)
        time.sleep(120)
        """
        let host = try Bench.host(named: "com.example.sleeper", program: sleeper,
                                  programName: "\(marker).py", in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        #expect(Bench.isRunning(marker: marker))
        await connection.close()
        var stopped = false
        for _ in 0..<50 where !stopped {
            try await Task.sleep(for: .milliseconds(100))
            stopped = !Bench.isRunning(marker: marker)
        }
        #expect(stopped)
    }

    @Test("A program that ignores being asked to stop is stopped anyway")
    func stubbornProgramIsKilled() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let marker = "kylmora-stubborn-\(UUID().uuidString)"
        let stubborn = Bench.pythonPreamble + """
        import signal
        # \(marker)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        write_message({"ready": True})
        time.sleep(120)
        """
        let host = try Bench.host(named: "com.example.stubborn", program: stubborn,
                                  programName: "\(marker).py", in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        _ = try await connection.nextMessage()
        #expect(Bench.isRunning(marker: marker))
        await connection.close()
        var stopped = false
        for _ in 0..<80 where !stopped {
            try await Task.sleep(for: .milliseconds(100))
            stopped = !Bench.isRunning(marker: marker)
        }
        #expect(stopped)
    }

    @Test("Sending to a closed connection fails rather than doing nothing")
    func sendAfterClose() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.closed", program: Self.echo, in: root)
        let connection = NativeMessagingConnection(host: host)
        try await connection.open(as: Bench.identity)
        await connection.close()
        await #expect(throws: (any Error).self) {
            try await connection.send(try NativeMessagingFraming.data(from: ["x": 1]))
        }
    }

    @Test("A host that cannot be started is reported, not retried forever")
    func launchFailure() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        // A file that is executable but is not a program: the kernel refuses it.
        let executable = Bench.program("this is not a program", named: "broken", in: root)
        let manifestURL = Bench.manifest(name: "com.example.broken", path: executable.path(percentEncoded: false), in: root)
        let host = try NativeMessagingHost.read(manifestURL, in: Bench.directory(root))
        let connection = NativeMessagingConnection(host: host)
        do {
            try await connection.open(as: Bench.identity)
            // Some kernels accept a text file and let the shell fail instead,
            // in which case the failure shows up as the host exiting at once.
            await #expect(throws: (any Error).self) {
                _ = try await connection.request(try NativeMessagingFraming.data(from: [:]), timeout: .seconds(5))
            }
        } catch let failure as NativeMessagingConnection.Failure {
            guard case .launchFailed = failure else {
                Issue.record("Expected a launch failure, got \(failure)")
                return
            }
        }
        await connection.close()
    }

    @Test("Ten conversations at once stay separate")
    func concurrentConnections() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let host = try Bench.host(named: "com.example.parallel", program: Self.echo, in: root)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<10 {
                group.addTask {
                    let connection = NativeMessagingConnection(host: host)
                    try await connection.open(as: Bench.identity)
                    let payload = try NativeMessagingFraming.data(from: ["n": index])
                    let reply = try await connection.request(payload, timeout: .seconds(20))
                    await connection.close()
                    let value = try NativeMessagingFraming.message(from: reply) as? [String: Any]
                    return (value?["echo"] as? [String: Any])?["n"] as? Int ?? -1
                }
            }
            var seen: Set<Int> = []
            for try await value in group { seen.insert(value) }
            #expect(seen == Set(0..<10))
        }
    }
}

// MARK: - The gates

@Suite("Nothing is started unless every gate opens", .serialized)
@MainActor
struct NativeMessagingServiceTests {
    private func makeService(root: URL, suite: String = UUID().uuidString) -> (NativeMessagingService, Settings, EnterprisePolicyManager) {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(suite)")!
        let settings = Settings(defaults: defaults)
        let policies = EnterprisePolicyManager(defaults: defaults)
        let registry = NativeMessagingHostRegistry(directories: [Bench.directory(root)])
        return (NativeMessagingService(registry: registry, settings: settings, policies: policies), settings, policies)
    }

    private static let echo = Bench.pythonPreamble + """
    while True:
        message = read_message()
        if message is None:
            break
        write_message({"echo": message})
    """

    @Test("An extension with everything in order reaches the host")
    func happyPath() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.service", program: Self.echo, in: root)
        let (service, _, _) = makeService(root: root)
        let reply = try await service.send(["ping": true], toHostNamed: "com.example.service",
                                           from: Bench.identity, hasPermission: true) as? [String: Any]
        #expect((reply?["echo"] as? [String: Any])?["ping"] as? Bool == true)
        #expect(service.events.first?.outcome == .replied)
        #expect(service.liveConnectionCount == 0)
    }

    @Test("An extension that did not ask for the permission is refused")
    func withoutPermission() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.service", program: Self.echo, in: root)
        let (service, _, _) = makeService(root: root)
        await #expect(throws: NativeMessagingService.Denial.permissionMissing) {
            _ = try await service.send(["ping": true], toHostNamed: "com.example.service",
                                       from: Bench.identity, hasPermission: false)
        }
    }

    @Test("A host the manifest does not name this extension in is refused")
    func notAllowed() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.private", program: Self.echo,
                           origins: ["chrome-extension://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/"], in: root)
        let (service, _, _) = makeService(root: root)
        await #expect(throws: NativeMessagingService.Denial.notAllowedByHost("com.example.private")) {
            _ = try await service.send(["ping": true], toHostNamed: "com.example.private",
                                       from: Bench.identity, hasPermission: true)
        }
    }

    @Test("A host nobody installed is refused, in Chrome's words")
    func unknownHost() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let (service, _, _) = makeService(root: root)
        await #expect(throws: NativeMessagingService.Denial.noSuchHost("com.example.absent")) {
            _ = try await service.send(["ping": true], toHostNamed: "com.example.absent",
                                       from: Bench.identity, hasPermission: true)
        }
        let error = NativeMessagingService.error(NativeMessagingService.Denial.noSuchHost("x"))
        #expect(error.localizedDescription == "Specified native messaging host not found.")
    }

    @Test("Switching the feature off stops every host")
    func switchedOff() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.service", program: Self.echo, in: root)
        let (service, settings, _) = makeService(root: root)
        settings.nativeMessagingEnabled = false
        await #expect(throws: NativeMessagingService.Denial.turnedOff) {
            _ = try await service.send(["ping": true], toHostNamed: "com.example.service",
                                       from: Bench.identity, hasPermission: true)
        }
    }

    @Test("A host switched off by name is refused while the rest still work")
    func blockedHost() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.blocked", program: Self.echo, in: root)
        _ = try Bench.host(named: "com.example.allowed", program: Self.echo, in: root)
        let (service, _, _) = makeService(root: root)
        service.setBlocked(true, hostName: "com.example.blocked")
        #expect(service.isBlocked("com.example.blocked"))
        await #expect(throws: NativeMessagingService.Denial.hostBlocked("com.example.blocked")) {
            _ = try await service.send(["ping": true], toHostNamed: "com.example.blocked",
                                       from: Bench.identity, hasPermission: true)
        }
        let reply = try await service.send(["ping": true], toHostNamed: "com.example.allowed",
                                           from: Bench.identity, hasPermission: true) as? [String: Any]
        #expect(reply?["echo"] != nil)
    }

    @Test("An organisation can switch native messaging off entirely")
    func policyOff() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.service", program: Self.echo, in: root)
        let (service, _, policies) = makeService(root: root)
        policies.setMockPolicies([.nativeMessagingDisabled: true])
        defer { policies.clearMockPolicies() }
        await #expect(throws: NativeMessagingService.Denial.blockedByPolicy) {
            _ = try await service.send(["ping": true], toHostNamed: "com.example.service",
                                       from: Bench.identity, hasPermission: true)
        }
    }

    @Test("An organisation can allow only the hosts it has approved")
    func policyAllowlist() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        _ = try Bench.host(named: "com.example.approved", program: Self.echo, in: root)
        _ = try Bench.host(named: "com.example.other", program: Self.echo, in: root)
        let (service, _, policies) = makeService(root: root)
        policies.setMockPolicies([.nativeMessagingHostAllowlist: ["com.example.approved"]])
        defer { policies.clearMockPolicies() }
        await #expect(throws: NativeMessagingService.Denial.blockedByPolicy) {
            _ = try await service.send(["ping": true], toHostNamed: "com.example.other",
                                       from: Bench.identity, hasPermission: true)
        }
        let reply = try await service.send(["ping": true], toHostNamed: "com.example.approved",
                                           from: Bench.identity, hasPermission: true) as? [String: Any]
        #expect(reply?["echo"] != nil)
    }

    @Test("A name that is really a path is refused before anything is looked up")
    func pathAsName() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let (service, _, _) = makeService(root: root)
        for name in ["../../../../bin/sh", "/bin/sh", "com.example/../escape"] {
            await #expect(throws: (any Error).self) {
                _ = try await service.send([:], toHostNamed: name, from: Bench.identity, hasPermission: true)
            }
        }
    }

    @Test("An extension that names no host is refused")
    func noHostNamed() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let (service, _, _) = makeService(root: root)
        await #expect(throws: NativeMessagingService.Denial.noHostNamed) {
            _ = try await service.send([:], toHostNamed: nil, from: Bench.identity, hasPermission: true)
        }
        await #expect(throws: NativeMessagingService.Denial.noHostNamed) {
            _ = try await service.send([:], toHostNamed: "", from: Bench.identity, hasPermission: true)
        }
    }

    @Test("Every refusal is written down with a reason a person can read")
    func refusalsAreRecorded() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let (service, _, _) = makeService(root: root)
        _ = try? await service.send([:], toHostNamed: "com.example.absent", from: Bench.identity, hasPermission: true)
        let event = service.events.first
        #expect(event?.hostName == "com.example.absent")
        #expect(event?.extensionName == "Test Extension")
        if case .refused(let reason) = event?.outcome {
            #expect(reason.contains("No app on this Mac"))
        } else {
            Issue.record("Expected a refusal, got \(String(describing: event?.outcome))")
        }
    }

    @Test("A host that fails is written down with what it said")
    func failuresAreRecorded() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let failing = Bench.pythonPreamble + """
        sys.stderr.write("no vault here\\n")
        sys.exit(9)
        """
        _ = try Bench.host(named: "com.example.failing", program: failing, in: root)
        let (service, _, _) = makeService(root: root)
        _ = try? await service.send([:], toHostNamed: "com.example.failing", from: Bench.identity, hasPermission: true)
        if case .failed(let detail) = service.events.first?.outcome {
            #expect(detail.contains("no vault here"))
        } else {
            Issue.record("Expected a failure, got \(String(describing: service.events.first?.outcome))")
        }
    }

    @Test("Only the last fifty things that happened are kept")
    func eventsAreBounded() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let (service, _, _) = makeService(root: root)
        for index in 0..<60 {
            _ = try? await service.send([:], toHostNamed: "com.example.absent\(index)",
                                        from: Bench.identity, hasPermission: true)
        }
        #expect(service.events.count == 50)
        #expect(service.events.first?.hostName == "com.example.absent59")
    }

    @Test("Leaving other browsers' folders out hides their hosts")
    func borrowingCanBeTurnedOff() async throws {
        let root = Bench.makeRoot()
        defer { Bench.remove(root) }
        let theirs = root.appending(path: "chrome", directoryHint: .isDirectory)
        _ = try Bench.host(named: "com.example.borrowed", program: Self.echo, in: theirs)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let registry = NativeMessagingHostRegistry(directories: [
            Bench.directory(theirs, label: "Google Chrome", own: false),
        ])
        let service = NativeMessagingService(registry: registry, settings: settings,
                                             policies: EnterprisePolicyManager(defaults: defaults))
        settings.nativeMessagingUsesOtherBrowsers = false
        await #expect(throws: NativeMessagingService.Denial.noSuchHost("com.example.borrowed")) {
            _ = try await service.send([:], toHostNamed: "com.example.borrowed",
                                       from: Bench.identity, hasPermission: true)
        }
        settings.nativeMessagingUsesOtherBrowsers = true
        let reply = try await service.send(["ping": 1], toHostNamed: "com.example.borrowed",
                                           from: Bench.identity, hasPermission: true) as? [String: Any]
        #expect(reply?["echo"] != nil)
    }
}
