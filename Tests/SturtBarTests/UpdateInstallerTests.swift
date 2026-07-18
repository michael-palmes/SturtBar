// UpdateInstallerTests.swift — the installer's pure seams: bundle-location classification,
// quoting for the elevated swap, and Info.plist reading. The Sec*/Process steps are exercised
// manually against real signed builds (see the PR's verification notes).

import Foundation
import Testing
@testable import SturtBar

struct UpdateInstallerTests {
    private let home = "/Users/keeper"

    @Test
    func `classifies translocated, mounted, temp and Downloads paths as reveal-only`() {
        let reveal = [
            "/private/var/folders/ab/xyz/T/AppTranslocation/1234/d/SturtBar.app",
            "/Volumes/SturtBar/SturtBar.app",
            "/private/var/folders/ab/xyz/T/SturtBar.app",
            "/var/folders/ab/xyz/T/SturtBar.app",
            "/tmp/SturtBar.app",
            "/private/tmp/SturtBar.app",
            "\(self.home)/Downloads/SturtBar.app",
        ]
        for path in reveal {
            #expect(
                UpdateInstaller.classifyBundleLocation(path: path, homeDirectory: self.home)
                    == .revealOnly,
                "\(path)")
        }
    }

    @Test
    func `classifies Applications and user locations as in-place`() {
        let inPlace = [
            "/Applications/SturtBar.app",
            "\(self.home)/Applications/SturtBar.app",
            "\(self.home)/Desktop/SturtBar.app",
        ]
        for path in inPlace {
            #expect(
                UpdateInstaller.classifyBundleLocation(path: path, homeDirectory: self.home)
                    == .installInPlace,
                "\(path)")
        }
    }

    @Test
    func `shell quoting survives apostrophes and AppleScript quoting survives quotes`() {
        #expect(UpdateInstaller.shellQuoted("/Applications/It's.app") == "'/Applications/It'\\''s.app'")
        #expect(UpdateInstaller.appleScriptQuoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }

    @Test
    func `the elevated swap script moves, replaces and restores on failure`() {
        let script = UpdateInstaller.elevatedSwapScript(
            targetPath: "/Applications/SturtBar.app",
            stagedPath: "/Users/keeper/Library/Application Support/SturtBar/Updates/9.9.9/SturtBar.app")
        #expect(script.contains("'/Applications/SturtBar.app'"))
        #expect(script.contains("'/Users/keeper/Library/Application Support/SturtBar/Updates/9.9.9/SturtBar.app'"))
        // Restore branch: a failed move puts the old bundle back and exits non-zero.
        #expect(script.contains(#"else /bin/mv "$OLD" '/Applications/SturtBar.app'; exit 1"#))
    }

    @Test
    func `reads bundle id and version from a bundle's Info plist`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-installer-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("SturtBar.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.michaelpalmes.sturtbar",
            "CFBundleShortVersionString": "9.9.9",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let info = UpdateInstaller.bundleInfo(at: appURL)
        #expect(info.bundleID == "com.michaelpalmes.sturtbar")
        #expect(info.version == "9.9.9")

        let missing = UpdateInstaller.bundleInfo(at: root.appendingPathComponent("Nope.app"))
        #expect(missing.bundleID == nil)
        #expect(missing.version == nil)
    }
}
