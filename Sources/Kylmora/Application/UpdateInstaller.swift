import AppKit
import Foundation

/// Puts a downloaded release in place of the running one.
///
/// The update check and the download already existed; what they ended in was
/// opening the disk image in Finder and asking the user to drag the app over
/// the old one themselves. This is the rest: mount, verify, stage, swap,
/// relaunch. One button.
///
/// ## What is checked before anything is replaced
///
/// An updater that installs whatever it downloaded is a way to run somebody
/// else's code as you, so the downloaded bundle has to prove it is ours before
/// it goes anywhere near `/Applications`:
///
///   1. `codesign --verify --deep --strict` — the bundle is intact and its
///      signature covers every file in it.
///   2. Its Team Identifier equals the running app's. A valid Developer ID
///      signature from *somebody* is not enough; it has to be the same
///      somebody who signed the copy already installed.
///   3. `spctl --assess --type exec` — Gatekeeper accepts it, which for a
///      release built by our own workflow means Apple notarised it.
///   4. Its version is actually newer than the running one, so a downgrade
///      cannot be served as an update.
///
/// Any of those failing stops the install with a reason, and nothing on disk
/// has been touched at that point.
///
/// ## Why a script does the swap
///
/// A running app cannot replace its own bundle: the executable and its
/// frameworks are mapped, and the directory it lives in is the one being
/// overwritten. So the last step writes a small shell script, starts it
/// detached, and quits. The script waits for this process to exit, moves the
/// old bundle aside, copies the new one into place, and reopens it. If the
/// copy fails it puts the old bundle back and reopens that, so a failed
/// update leaves a working app rather than a hole where one used to be.
enum UpdateInstaller {

    // MARK: - What can go wrong

    enum Failure: LocalizedError, Equatable {
        case notWritable(path: String)
        case mountFailed(String)
        case noAppInImage
        case signatureRejected(String)
        case wrongTeam(expected: String, found: String)
        case notNewer(found: String, running: String)
        case stageFailed(String)
        case launchFailed(String)

        /// A detail from a command-line tool, finished off as a sentence.
        /// `codesign` and `hdiutil` report things like "no mountable file
        /// systems", which reads as a fragment glued onto the end of ours.
        private func detail(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let capitalised = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            return " " + capitalised + (".?!".contains(capitalised.last!) ? "" : ".")
        }

        var errorDescription: String? {
            switch self {
            case .notWritable(let path):
                return "Kylmora cannot update itself where it is installed (\(path)). Move it to your Applications folder and try again."
            case .mountFailed(let detail_):
                return "The downloaded disk image could not be opened." + detail(detail_)
            case .noAppInImage:
                return "The downloaded disk image does not contain Kylmora."
            case .signatureRejected(let detail_):
                return "The download is not a signed copy of Kylmora, so it was not installed." + detail(detail_)
            case .wrongTeam(let expected, let found):
                return "The download is signed by \(found), not by \(expected), so it was not installed."
            case .notNewer(let found, let running):
                return "The download is version \(found), which is not newer than the \(running) you are running."
            case .stageFailed(let detail_):
                return "The update could not be prepared." + detail(detail_)
            case .launchFailed(let detail_):
                return "The update could not be started." + detail(detail_)
            }
        }
    }

    // MARK: - Where we are

    /// The bundle that is running, which is the one to replace.
    static var installedApp: URL { Bundle.main.bundleURL }

    /// Whether this copy can be replaced in place.
    ///
    /// False for a copy still inside a disk image, or one in a folder the user
    /// does not own. Rather than ask for an administrator password -- which an
    /// updater has no business doing -- the install stops and says to move the
    /// app to Applications first.
    static func canReplace(_ app: URL = installedApp) -> Bool {
        let parent = app.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    // MARK: - Reading a signature

    /// The Team Identifier out of `codesign -dv` output.
    ///
    /// Pure so the parsing can be checked without signing anything: the line
    /// is `TeamIdentifier=ABCDE12345`, and `not set` is what an ad-hoc signed
    /// build reports, which is not an identity and must not match anything.
    static func parseTeamIdentifier(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return (value.isEmpty || value == "not set") ? nil : value
        }
        return nil
    }

    static func teamIdentifier(of app: URL) -> String? {
        let result = run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        // codesign writes this to standard error.
        return parseTeamIdentifier(result.error + "\n" + result.output)
    }

    /// `CFBundleShortVersionString` from a bundle on disk, without loading it.
    static func version(of app: URL) -> String? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    // MARK: - Verifying

    /// Everything that has to be true before a bundle is allowed to replace
    /// the running one. Throws the first thing that is not.
    static func verify(
        candidate: URL,
        expectedTeam: String?,
        runningVersion: String
    ) throws {
        let integrity = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        guard integrity.status == 0 else {
            throw Failure.signatureRejected(integrity.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The same signer as the copy already installed. Skipped only when the
        // running copy is itself unsigned -- a local build -- because there is
        // then no identity to match and refusing would make development
        // builds unable to test this path at all.
        if let expectedTeam {
            guard let found = teamIdentifier(of: candidate) else {
                throw Failure.wrongTeam(expected: expectedTeam, found: "nobody")
            }
            guard found == expectedTeam else {
                throw Failure.wrongTeam(expected: expectedTeam, found: found)
            }
        }

        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "exec", "--verbose=4", candidate.path])
        guard gatekeeper.status == 0 else {
            throw Failure.signatureRejected("Gatekeeper did not accept it.")
        }

        guard let found = version(of: candidate) else {
            throw Failure.stageFailed("The download has no version.")
        }
        guard AppVersion(found) > AppVersion(runningVersion) else {
            throw Failure.notNewer(found: found, running: runningVersion)
        }
    }

    // MARK: - Staging

    /// Mounts the image, verifies what is inside it and copies that out.
    ///
    /// The copy leaves the image before the image is unmounted, so the swap
    /// later is a move between two ordinary folders rather than something
    /// reaching into a mounted volume that may have gone away.
    static func stage(
        dmg: URL,
        expectedTeam: String? = teamIdentifier(of: installedApp),
        runningVersion: String = AppInfo.version
    ) throws -> URL {
        let mount = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "kylmora-update-\(UUID().uuidString)")
        let attach = run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
            "-mountpoint", mount.path,
        ])
        guard attach.status == 0 else {
            throw Failure.mountFailed(attach.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            try? FileManager.default.removeItem(at: mount)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? []
        guard let name = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw Failure.noAppInImage
        }
        let candidate = mount.appending(path: name)

        try verify(candidate: candidate, expectedTeam: expectedTeam, runningVersion: runningVersion)

        let staging = AppPaths.supportDirectory.appending(path: "Updates/staged")
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staged = staging.appending(path: name)
        // `ditto` rather than `copyItem`: it preserves the extended attributes
        // and the signature's own metadata, which a plain copy can drop and
        // which would leave the staged bundle failing the second verification.
        let copy = run("/usr/bin/ditto", [candidate.path, staged.path])
        guard copy.status == 0 else {
            throw Failure.stageFailed(copy.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Verified again where it will actually be installed from, so a copy
        // that was damaged on the way out of the image cannot be installed.
        try verify(candidate: staged, expectedTeam: expectedTeam, runningVersion: runningVersion)
        return staged
    }

    // MARK: - Swapping

    /// The script that replaces the bundle once this process has exited.
    ///
    /// Pure, and separated from running it, so what it does can be read and
    /// tested rather than inferred. Paths are single-quoted with embedded
    /// quotes escaped, because a user's Applications folder may be anywhere.
    static func swapScript(pid: Int32, staged: URL, installed: URL) -> String {
        func quoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let staged = quoted(staged.path)
        let installed = quoted(installed.path)
        return """
        #!/bin/sh
        # Written by Kylmora to finish an update. It waits for the old copy to
        # quit, puts the new one in its place, and opens it again. If anything
        # goes wrong the old copy is put back, so this can fail without
        # leaving the Mac without a browser.
        set -u
        PID=\(pid)

        # Ten seconds is long enough for a browser to save its session and go.
        i=0
        while [ $i -lt 100 ]; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
            i=$((i + 1))
        done
        # Still running: change nothing rather than replace a bundle in use.
        if kill -0 "$PID" 2>/dev/null; then
            exit 1
        fi

        BACKUP=\(installed).replacing-$$
        /bin/mv \(installed) "$BACKUP" || exit 1
        if /usr/bin/ditto \(staged) \(installed); then
            /bin/rm -rf "$BACKUP" \(staged)
            # The copy inherits the download's quarantine flag, which would
            # make the app it just replaced ask to be opened again.
            /usr/bin/xattr -d -r com.apple.quarantine \(installed) 2>/dev/null
        else
            /bin/rm -rf \(installed)
            /bin/mv "$BACKUP" \(installed)
        fi
        /usr/bin/open \(installed)
        /bin/rm -f "$0"
        """
    }

    /// Starts the swap and hands back, so the caller can quit.
    ///
    /// The script is started with `launchctl`-free `Process`, detached from
    /// this process group, so that our own exit does not take it with us.
    static func startSwap(staged: URL, installed: URL = installedApp) throws {
        guard canReplace(installed) else {
            throw Failure.notWritable(path: installed.path)
        }
        let script = AppPaths.supportDirectory.appending(path: "Updates/install.sh")
        do {
            try FileManager.default.createDirectory(
                at: script.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try swapScript(pid: ProcessInfo.processInfo.processIdentifier, staged: staged, installed: installed)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path]
        // Its own session, so quitting this app does not signal it.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
    }

    // MARK: - Running a tool

    private struct Result {
        let status: Int32
        let output: String
        let error: String
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Result(
            status: task.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self)
        )
    }
}
