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

    @Test("lipo -archs is read into the slices a bundle carries")
    func architecturesAreParsed() {
        // What `lipo -archs` actually prints, with its trailing newline.
        #expect(UpdateInstaller.parseArchitectures("arm64\n") == ["arm64"])
        #expect(UpdateInstaller.parseArchitectures("x86_64 arm64\n") == ["x86_64", "arm64"])
        #expect(UpdateInstaller.parseArchitectures("") == [])
    }

    @Test("A build for the other kind of Mac is not offered as an update")
    func wrongArchitectureIsRefused() {
        // The danger this guards: an Apple Silicon only release is validly
        // signed, notarised and newer, so nothing else in `verify` objects to
        // it. On an Intel Mac installing it would replace a working browser
        // with one that cannot launch.
        let appleSiliconOnly = UpdateInstaller.parseArchitectures("arm64\n")
        #expect(!appleSiliconOnly.contains("x86_64"))

        // The universal build is the one that is safe for everybody, which is
        // why the update feed names it.
        let universal = UpdateInstaller.parseArchitectures("x86_64 arm64\n")
        #expect(universal.contains("x86_64"))
        #expect(universal.contains("arm64"))

        // Whatever this test is running as, the universal build carries it.
        #expect(universal.contains(UpdateInstaller.runningArchitecture))
    }

    @Test("Every failure explains itself in a sentence")
    func failuresReadAsEnglish() {
        let failures: [UpdateInstaller.Failure] = [
            .notWritable(path: "/Volumes/Kylmora/Kylmora.app"),
            .mountFailed("no mountable file systems"),
            .noAppInImage,
            .signatureRejected("code object is not signed at all"),
            .wrongTeam(expected: "S5QL4CMLV8", found: "XYZ123"),
            .wrongArchitecture(found: "arm64", running: "x86_64"),
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


/// The path from "the site says there is a new version" to "something is
/// downloading". This is where an update quietly turned into a web page.
@Suite("Finding the package to install")
struct UpdatePackageURLTests {

    private func feed(_ json: String) throws -> UpdateCheck.Release {
        try UpdateCheck.decode(Data(json.utf8))
    }

    @Test("The download address survives the answer being handed on")
    func downloadURLIsNotDropped() throws {
        // This is the bug. The outcome used to carry three of the release's
        // four fields, and the one it left behind was the address of the
        // package -- so everything downstream fell back to the release page,
        // downloaded a few kilobytes of HTML, found it was not a disk image
        // and opened it in a browser. One click "updated" you to a web page.
        let release = try feed("""
        {"version": "0.1.51",
         "url": "https://github.com/kylmora/kylmora/releases/latest",
         "downloadUrl": "https://github.com/kylmora/kylmora/releases/latest/download/Kylmora.dmg"}
        """)
        let outcome = UpdateCheck.outcome(current: "0.1.5", release: release)
        let carried = try #require(outcome.release)
        #expect(carried.downloadUrl == release.downloadUrl)
        #expect(carried.updatePackageURL?.pathExtension == "dmg")
    }

    @Test("A release page is never treated as a download")
    func aPageIsNotAPackage() throws {
        // A feed that only names a page has nothing to install. Saying so is
        // the honest answer; downloading the page is not.
        let pageOnly = try feed("""
        {"version": "0.2.0", "url": "https://github.com/kylmora/kylmora/releases/latest"}
        """)
        #expect(pageOnly.updatePackageURL == nil)
        #expect(pageOnly.url != nil, "the page is still there to open deliberately")
    }

    @Test("Only things that can be installed count as packages")
    func packageExtensions() {
        func isPackage(_ text: String) -> Bool {
            UpdateCheck.Release.isPackage(URL(string: text)!)
        }
        #expect(isPackage("https://example.com/Kylmora.dmg"))
        #expect(isPackage("https://example.com/Kylmora.pkg"))
        #expect(isPackage("https://example.com/Kylmora.zip"))
        #expect(!isPackage("https://github.com/kylmora/kylmora/releases/latest"))
        #expect(!isPackage("https://kylmora.com/download"))
        #expect(!isPackage("https://example.com/notes.html"))
    }

    @Test("The direct address wins over the page when the feed carries both")
    func prefersTheDirectAddress() throws {
        let both = try feed("""
        {"version": "0.2.0",
         "url": "https://kylmora.com/download",
         "downloadUrl": "https://example.com/Kylmora.dmg"}
        """)
        #expect(both.updatePackageURL?.absoluteString == "https://example.com/Kylmora.dmg")
    }

    @Test("A feed whose only address is a package is still usable")
    func packageInTheURLField() throws {
        // Older feeds put the .dmg in `url` and had no `downloadUrl` at all.
        let older = try feed("""
        {"version": "0.2.0", "url": "https://example.com/Kylmora.dmg"}
        """)
        #expect(older.updatePackageURL?.pathExtension == "dmg")
    }

    @Test("The live feed's shape is the one the updater expects")
    func theShapeWeActuallyPublish() throws {
        // Exactly what kylmora.com/releases/latest.json serves today. If the
        // site's shape and the browser's reading of it ever drift apart, the
        // update button stops working and nothing else fails first.
        let live = try feed("""
        {
          "version": "0.1.51",
          "url": "https://github.com/kylmora/kylmora/releases/latest",
          "dmg": "https://github.com/kylmora/kylmora/releases/latest/download/Kylmora.dmg",
          "pkg": "https://github.com/kylmora/kylmora/releases/latest/download/Kylmora.pkg",
          "downloadUrl": "https://github.com/kylmora/kylmora/releases/latest/download/Kylmora.dmg",
          "notes": "Kylmora updates itself now."
        }
        """)
        #expect(live.version == "0.1.51")
        #expect(live.updatePackageURL?.lastPathComponent == "Kylmora.dmg")
        #expect(UpdateCheck.outcome(current: "0.1.5", release: live).release?.updatePackageURL != nil)
        #expect(UpdateCheck.outcome(current: "0.1.51", release: live) == .upToDate(current: "0.1.51"))
    }
}
