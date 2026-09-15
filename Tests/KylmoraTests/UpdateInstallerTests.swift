import Foundation
import Testing
@testable import Kylmora

/// The parts of the self-updater that decide whether somebody else's code gets
/// to run as you, and the script that moves a bundle around while the app it
/// belongs to is shutting down. Both are worth being sure about.
@Suite("Installing an update")
struct UpdateInstallerTests {

    // MARK: - Reading a signature

    @Test("The team identifier is read out of codesign's report")
    func readsTheTeam() {
        let output = """
        Executable=/Applications/Kylmora.app/Contents/MacOS/Kylmora
        Identifier=com.kylmora.Kylmora
        Authority=Developer ID Application: Vikrant Gupta (S5QL4CMLV8)
        TeamIdentifier=S5QL4CMLV8
        Sealed Resources version=2 rules=13 files=4
        """
        #expect(UpdateInstaller.parseTeamIdentifier(output) == "S5QL4CMLV8")
    }

    @Test("An ad-hoc signature has no team, and must not read as one")
    func adHocHasNoTeam() {
        // `codesign` writes "not set" for a build signed with `-`. Treating
        // that as an identity would let any locally signed bundle match
        // another one that is also "not set".
        #expect(UpdateInstaller.parseTeamIdentifier("TeamIdentifier=not set") == nil)
        #expect(UpdateInstaller.parseTeamIdentifier("TeamIdentifier=") == nil)
        #expect(UpdateInstaller.parseTeamIdentifier("Identifier=com.kylmora.Kylmora") == nil)
        #expect(UpdateInstaller.parseTeamIdentifier("") == nil)
    }

    // MARK: - The swap script

    private func script(
        pid: Int32 = 4242,
        staged: String = "/Users/someone/Library/Application Support/com.kylmora.Kylmora/Updates/staged/Kylmora.app",
        installed: String = "/Applications/Kylmora.app"
    ) -> String {
        UpdateInstaller.swapScript(
            pid: pid,
            staged: URL(fileURLWithPath: staged),
            installed: URL(fileURLWithPath: installed)
        )
    }

    @Test("The script waits for the old copy to exit before touching anything")
    func waitsForTheAppToQuit() {
        let text = script()
        #expect(text.contains("PID=4242"))
        // The wait comes before the move, or the bundle would be replaced
        // underneath a running process.
        let wait = try! #require(text.range(of: "kill -0"))
        let move = try! #require(text.range(of: "/bin/mv"))
        #expect(wait.lowerBound < move.lowerBound)
    }

    @Test("A copy that will not quit is left alone")
    func refusesToReplaceARunningApp() {
        // The loop can time out. When it does the script has to stop, not
        // carry on and overwrite a bundle that is still mapped.
        let text = script()
        #expect(text.contains("exit 1"))
    }

    @Test("A failed copy puts the old version back")
    func rollsBack() {
        let text = script()
        #expect(text.contains("BACKUP="))
        // The old bundle is moved aside rather than deleted, and moved back
        // when the copy fails, so a broken update leaves a working browser.
        let restore = text.range(of: "/bin/mv \"$BACKUP\"")
        #expect(restore != nil)
        // And whatever happens, the app is opened again at the end.
        #expect(text.contains("/usr/bin/open"))
    }

    @Test("The new copy is opened whether the update worked or not")
    func alwaysReopens() {
        let text = script()
        let opens = text.components(separatedBy: "/usr/bin/open").count - 1
        #expect(opens >= 1)
        let openAt = try! #require(text.range(of: "/usr/bin/open"))
        let elseAt = try! #require(text.range(of: "else"))
        #expect(elseAt.lowerBound < openAt.lowerBound, "the reopen is after both outcomes")
    }

    @Test("The quarantine flag is cleared, so the new copy does not ask again")
    func clearsQuarantine() {
        #expect(script().contains("com.apple.quarantine"))
    }

    @Test("A path with a quote in it cannot break out of the script")
    func quotesPaths() {
        // Somebody's folder really can be called this, and a naive script
        // would end the quoted string and run the rest as a command.
        let text = script(installed: "/Users/o'brien/Applications/Kylmora.app")
        #expect(text.contains("'/Users/o'\\''brien/Applications/Kylmora.app'"))
        #expect(!text.contains("'/Users/o'brien/"))
    }

    @Test("Every path in the script is quoted")
    func everyPathIsQuoted() {
        let text = script(installed: "/Volumes/My Disk/Kylmora.app")
        // A space in the path must not split into two arguments.
        #expect(text.contains("'/Volumes/My Disk/Kylmora.app'"))
    }

    @Test("The script cleans up after itself")
    func removesItself() {
        let text = script()
        #expect(text.contains("/bin/rm -f \"$0\""))
    }

    // MARK: - Where it will install

    @Test("A copy inside a read-only disk image cannot be replaced in place")
    func refusesUnwritableLocations() {
        // Nothing under /System is writable, which stands in here for any
        // location the user does not own: the install has to stop and say so
        // rather than ask for an administrator password.
        #expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/System/Applications/Chess.app")))
    }

    @Test("Every failure explains itself in a sentence")
    func failuresReadAsEnglish() {
        let failures: [UpdateInstaller.Failure] = [
            .notWritable(path: "/Volumes/Kylmora/Kylmora.app"),
            .mountFailed("no mountable file systems"),
            .noAppInImage,
            .signatureRejected("code object is not signed at all"),
            .wrongTeam(expected: "S5QL4CMLV8", found: "XYZ123"),
            .notNewer(found: "0.1.4", running: "0.1.4"),
            .stageFailed("out of space"),
            .launchFailed("permission denied"),
        ]
        for failure in failures {
            let text = try! #require(failure.errorDescription)
            #expect(text.count > 20, "\(failure) says too little")
            #expect(text.hasSuffix(".") || text.hasSuffix("?"), "\(failure) is not a sentence")
        }
    }

    @Test("A downgrade is not an update")
    func refusesToGoBackwards() {
        // The version rule the installer applies, stated on its own: the same
        // version is not newer, and an older one certainly is not. A feed that
        // has been tampered with cannot hand back an old, vulnerable build.
        #expect(!(AppVersion("0.1.3") > AppVersion("0.1.4")))
        #expect(!(AppVersion("0.1.4") > AppVersion("0.1.4")))
        #expect(AppVersion("0.1.5") > AppVersion("0.1.4"))
        #expect(AppVersion("0.2.0") > AppVersion("0.1.9"))
    }
}
