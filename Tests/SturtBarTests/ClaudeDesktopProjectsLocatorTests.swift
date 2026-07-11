// ClaudeDesktopProjectsLocatorTests.swift: locator behaviour for Claude Desktop's transcript stores.

import Foundation
import Testing
@testable import SturtBarCore

struct ClaudeDesktopProjectsLocatorTests {
    @Test
    func `finds embedded projects stores under both session roots`() throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let agentProjects = Self.appSupportClaude(home)
            .appendingPathComponent("local-agent-mode-sessions/workspace/session-1/.claude/projects")
        let codeProjects = Self.appSupportClaude(home)
            .appendingPathComponent("claude-code-sessions/account/workspace/.claude/projects")
        try FileManager.default.createDirectory(at: agentProjects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codeProjects, withIntermediateDirectories: true)

        let roots = ClaudeDesktopProjectsLocator.roots(homeDirectory: home)
        let paths = Set(roots.map(\.path))
        #expect(paths.contains(agentProjects.standardizedFileURL.path))
        #expect(paths.contains(codeProjects.standardizedFileURL.path))
        #expect(roots.count == 2)
    }

    @Test
    func `returns nothing when the desktop roots do not exist`() throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(ClaudeDesktopProjectsLocator.roots(homeDirectory: home).isEmpty)
    }

    @Test
    func `does not descend past the depth bound`() throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Depth 5 below the session root: one level too deep for the walk.
        let tooDeep = Self.appSupportClaude(home)
            .appendingPathComponent("local-agent-mode-sessions/a/b/c/d/e/.claude/projects")
        try FileManager.default.createDirectory(at: tooDeep, withIntermediateDirectories: true)

        #expect(ClaudeDesktopProjectsLocator.roots(homeDirectory: home).isEmpty)
    }

    @Test
    func `skips heavy directories and symlinks`() throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let sessions = Self.appSupportClaude(home)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        let insideNodeModules = sessions.appendingPathComponent("node_modules/pkg/.claude/projects")
        try FileManager.default.createDirectory(at: insideNodeModules, withIntermediateDirectories: true)

        // A symlinked child pointing at a real store elsewhere must not be followed.
        let external = home.appendingPathComponent("elsewhere/session/.claude/projects")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let link = sessions.appendingPathComponent("linked-session")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: home.appendingPathComponent("elsewhere/session"))

        #expect(ClaudeDesktopProjectsLocator.roots(homeDirectory: home).isEmpty)
    }

    // MARK: - Helpers

    private static func appSupportClaude(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    private static func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-desktop-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
