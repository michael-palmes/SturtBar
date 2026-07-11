import Foundation
import Synchronization
import Testing
@testable import SturtBar

@MainActor
struct TerminalLoginLauncherTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-launcher-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test
    func `script contents are the exact expected zsh helper`() {
        let expected = """
        #!/bin/zsh -l
        # SturtBar sign-in helper. Generated on demand; safe to delete.
        cd "$HOME" || exit 1
        if command -v claude >/dev/null 2>&1; then
          exec claude /login
        fi
        echo ""
        echo "SturtBar could not find the claude command on your PATH."
        echo "Install Claude Code, then use the sign-in line in the SturtBar menu again."
        echo ""
        read -s -k 1 "?Press any key to close this window."

        """
        #expect(TerminalLoginLauncher.scriptContents(for: .claude) == expected)
    }

    @Test
    func `launch writes an executable script and opens it`() throws {
        let directory = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let opened = Mutex<URL?>(nil)
        let launcher = TerminalLoginLauncher(
            scriptDirectory: directory,
            open: { url in
                opened.withLock { $0 = url }
                return true
            })

        #expect(launcher.launch(.claude))

        let scriptURL = directory.appendingPathComponent("SturtBar Claude sign-in.command")
        #expect(opened.withLock { $0 } == scriptURL)
        let contents = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(contents == TerminalLoginLauncher.scriptContents(for: .claude))
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test
    func `launch overwrites a previous script`() throws {
        let directory = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("SturtBar Claude sign-in.command")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale contents".utf8).write(to: scriptURL)

        let launcher = TerminalLoginLauncher(scriptDirectory: directory, open: { _ in true })
        #expect(launcher.launch(.claude))

        let contents = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(contents == TerminalLoginLauncher.scriptContents(for: .claude))
    }

    @Test
    func `launch reports failure when the open handler declines`() {
        let directory = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = TerminalLoginLauncher(scriptDirectory: directory, open: { _ in false })
        #expect(!launcher.launch(.claude))
    }

    @Test
    func `launch reports failure when the script cannot be written`() {
        // A file where the directory should be makes createDirectory throw.
        let base = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let blockedDirectory = base.appendingPathComponent("blocked", isDirectory: true)
        FileManager.default.createFile(atPath: blockedDirectory.path, contents: Data())

        let openCalled = Mutex(false)
        let launcher = TerminalLoginLauncher(
            scriptDirectory: blockedDirectory,
            open: { _ in
                openCalled.withLock { $0 = true }
                return true
            })
        #expect(!launcher.launch(.claude))
        #expect(openCalled.withLock { $0 } == false)
    }
}
