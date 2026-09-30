// TerminalLoginLauncher.swift — writes a .command script and opens it in the user's default
// terminal for a provider sign-in or renewal. SturtBar never runs the CLI; the token is read on the next fetch.
//
// The script lives in (and cds to) `~/.sturtbar`, deliberately NOT Application Support: macOS 26
// app-data protection prompts when the terminal reads another app's container, and a `cd "$HOME"`
// made Claude Code ask the user to trust their entire home directory. The dedicated folder holds
// only this script, so the CLI's one-time workspace trust covers nothing sensitive.

import AppKit
import SturtBarCore

@MainActor
struct TerminalLoginLauncher {
    enum Command {
        case claude
        /// Starts Claude Code interactively so it renews its own sign-in (`claude -p` would spend usage).
        case claudeRenew

        var executableName: String {
            switch self {
            case .claude, .claudeRenew: "claude"
            }
        }

        var arguments: [String] {
            switch self {
            case .claude: ["/login"]
            case .claudeRenew: []
            }
        }

        /// Also the terminal window title while the script runs.
        var scriptFileName: String {
            switch self {
            case .claude: "SturtBar Claude sign-in.command"
            case .claudeRenew: "SturtBar Claude Code.command"
            }
        }

        /// Full product name for the missing-binary message.
        var productName: String {
            switch self {
            case .claude, .claudeRenew: "Claude Code"
            }
        }

        /// Banner line, also the script's header comment.
        var bannerTitle: String {
            switch self {
            case .claude: "SturtBar sign-in helper"
            case .claudeRenew: "SturtBar: opening Claude Code"
            }
        }

        /// The card line that launched this helper, for the missing-binary retry hint.
        var menuLine: String {
            switch self {
            case .claude: "sign-in line"
            case .claudeRenew: "waiting line"
            }
        }

        /// Printed under the banner, before the folder note.
        var introLines: [String] {
            switch self {
            case .claude:
                []
            case .claudeRenew:
                ["Opening Claude Code so it can renew its sign-in. Once it starts,", "you can quit with /exit."]
            }
        }

        /// When the CLI's workspace trust prompt can appear.
        var trustPromptMoment: String {
            switch self {
            case .claude: "first sign-in only"
            case .claudeRenew: "first time only"
            }
        }
    }

    /// Directory the script is written to; injectable for tests.
    var scriptDirectory: URL
    /// Pre-`~/.sturtbar` script location; the stale helper there is removed on the next launch
    /// (reading it from Application Support triggered the macOS app-data prompt). Injectable for tests.
    var legacyScriptDirectory: URL?
    /// Opens the script with its default handler; injectable for tests.
    var open: (URL) -> Bool

    private static let log = SturtBarLog.logger("terminal-login")

    init(
        scriptDirectory: URL? = nil,
        open: ((URL) -> Bool)? = nil)
    {
        self.scriptDirectory = scriptDirectory ?? Self.defaultScriptDirectory()
        self.legacyScriptDirectory = scriptDirectory == nil ? Self.legacyDefaultScriptDirectory() : nil
        self.open = open ?? { NSWorkspace.shared.open($0) }
    }

    /// The generated script, exact-match testable. Login shell resolves the user's PATH; a missing binary keeps the
    /// window open. Runs from the script's own folder so the CLI's workspace prompt covers nothing else.
    static func scriptContents(for command: Command) -> String {
        let executable = command.executableName
        let invocation = ([executable] + command.arguments).joined(separator: " ")
        let intro = command.introLines.isEmpty
            ? ""
            : command.introLines.map { "echo \"  \($0)\"\n" }.joined() + "echo \"\"\n"
        return """
        #!/bin/zsh -l
        # \(command.bannerTitle). Generated on demand; safe to delete.
        # Runs in SturtBar's own folder so any \(command.productName) workspace prompt covers nothing else.
        cd "$(dirname "$0")" || exit 1
        print -P "%F{173}──────────────────────────────────────────────────────────────────────%f"
        print -P "%B%F{173}  \(command.bannerTitle)%f%b"
        print -P "%F{173}──────────────────────────────────────────────────────────────────────%f"
        echo ""
        \(intro)echo "  This window runs from ~/.sturtbar, SturtBar's own folder. It holds only"
        echo "  this script."
        echo ""
        echo "  If \(command.productName) asks you to trust this workspace (\(command.trustPromptMoment)):"
        print -P "    %F{green}✓%f the trust covers this folder alone"
        print -P "    %F{red}✗%f never your home directory, your files or your other projects"
        echo ""
        if command -v \(executable) >/dev/null 2>&1; then
          print -P "  %F{173}Opening \(command.productName) (\(invocation)) in 3 seconds...%f"
          sleep 3
          exec \(invocation)
        fi
        echo ""
        echo "SturtBar could not find the \(executable) command on your PATH."
        echo "Install \(command.productName), then use the \(command.menuLine) in the SturtBar menu again."
        echo ""
        read -s -k 1 "?Press any key to close this window."

        """
    }

    /// Writes the script (0700) and opens it. Returns false on failure so the card line stays clickable.
    @discardableResult
    func launch(_ command: Command) -> Bool {
        if let legacy = self.legacyScriptDirectory {
            try? FileManager.default.removeItem(
                at: legacy.appendingPathComponent(command.scriptFileName, isDirectory: false))
        }
        let scriptURL = self.scriptDirectory.appendingPathComponent(
            command.scriptFileName,
            isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: self.scriptDirectory,
                withIntermediateDirectories: true)
            try Data(Self.scriptContents(for: command).utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path)
        } catch {
            Self.log.error(
                "Sign-in helper script write failed",
                metadata: ["error": error.localizedDescription])
            return false
        }

        guard self.open(scriptURL) else {
            let handler = NSWorkspace.shared.urlForApplication(toOpen: scriptURL)
            Self.log.error(
                "Sign-in helper open failed",
                metadata: ["handler": handler?.lastPathComponent ?? "none"])
            return false
        }
        Self.log.info("Sign-in helper opened", metadata: ["command": command.executableName])
        return true
    }

    static func defaultScriptDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sturtbar", isDirectory: true)
    }

    static func legacyDefaultScriptDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("SturtBar", isDirectory: true)
    }
}
