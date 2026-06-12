// MenuBarProviderResolverTests.swift — "most-constrained wins" + the forced-provider override
// (decisions 10+11), and IconState's multi-provider derivation built on top of it.

import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

struct MenuBarProviderResolverPureTests {
    private func snap(_ usedPercent: Double) -> ProviderUsageSnapshot {
        makeUsageSnapshot(primaryUsedPercent: usedPercent)
    }

    @Test
    func `auto picks the provider with the highest primary used percent`() {
        let winner = MenuBarProviderResolver.winner(
            source: .auto,
            claudeEnabled: true,
            claude: self.snap(40),
            codexEnabled: true,
            codex: self.snap(81))
        #expect(winner == .codex)

        let flipped = MenuBarProviderResolver.winner(
            source: .auto,
            claudeEnabled: true,
            claude: self.snap(90),
            codexEnabled: true,
            codex: self.snap(81))
        #expect(flipped == .claude)
    }

    @Test
    func `auto breaks ties in canonical order`() {
        let winner = MenuBarProviderResolver.winner(
            source: .auto,
            claudeEnabled: true,
            claude: self.snap(50),
            codexEnabled: true,
            codex: self.snap(50))
        #expect(winner == .claude)
    }

    @Test
    func `auto ignores providers without data`() {
        let winner = MenuBarProviderResolver.winner(
            source: .auto,
            claudeEnabled: true,
            claude: nil,
            codexEnabled: true,
            codex: self.snap(5))
        #expect(winner == .codex)
    }

    @Test
    func `auto with no data falls back to the first enabled provider`() {
        let both = MenuBarProviderResolver.winner(
            source: .auto,
            claudeEnabled: true,
            claude: nil,
            codexEnabled: true,
            codex: nil)
        #expect(both == .claude)

        let codexOnly = MenuBarProviderResolver.winner(
            source: .auto,
            claudeEnabled: false,
            claude: nil,
            codexEnabled: true,
            codex: nil)
        #expect(codexOnly == .codex)
    }

    @Test
    func `forced source wins regardless of usage`() {
        let winner = MenuBarProviderResolver.winner(
            source: .claude,
            claudeEnabled: true,
            claude: self.snap(10),
            codexEnabled: true,
            codex: self.snap(99))
        #expect(winner == .claude)
    }

    @Test
    func `forced-but-disabled source falls back to auto`() {
        let winner = MenuBarProviderResolver.winner(
            source: .codex,
            claudeEnabled: true,
            claude: self.snap(10),
            codexEnabled: false,
            codex: nil)
        #expect(winner == .claude)
    }

    @Test
    func `nothing enabled resolves to nil`() {
        let winner = MenuBarProviderResolver.winner(
            source: .auto,
            claudeEnabled: false,
            claude: nil,
            codexEnabled: false,
            codex: nil)
        #expect(winner == nil)
    }

    @Test
    func `prefix applies only in multi-provider mode`() {
        #expect(MenuBarProviderResolver.prefixed("81%", provider: .codex, multiProvider: true) == "X 81%")
        #expect(MenuBarProviderResolver.prefixed("45%", provider: .claude, multiProvider: true) == "C 45%")
        #expect(MenuBarProviderResolver.prefixed("45%", provider: .claude, multiProvider: false) == "45%")
        #expect(MenuBarProviderResolver.prefixed(nil, provider: .codex, multiProvider: true) == nil)
    }
}

// MARK: - IconState integration

@MainActor
struct IconStateMultiProviderTests {
    @Test
    func `most constrained provider drives buckets and prefixed text`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-icon-multi-codex-wins",
            codexFetch: { makeCodexSnapshot(primaryUsedPercent: 81, secondaryUsedPercent: 30) },
            fetch: { _, _ in makeUsageSnapshot(primaryUsedPercent: 40, secondaryUsedPercent: 10) })
        ts.settings.codexProviderEnabled = true
        ts.settings.menuBarDisplayMode = .percent
        await ts.store.refresh(trigger: .manual)

        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.primaryBucket == 19) // codex: 81 used → 19 remaining
        #expect(state.secondaryBucket == 70)
        #expect(state.displayText == "X 19%")
    }

    @Test
    func `claude wins when more constrained and keeps its prefix`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-icon-multi-claude-wins",
            codexFetch: { makeCodexSnapshot(primaryUsedPercent: 10, secondaryUsedPercent: nil) },
            fetch: { _, _ in makeUsageSnapshot(primaryUsedPercent: 90) })
        ts.settings.codexProviderEnabled = true
        ts.settings.menuBarDisplayMode = .percent
        await ts.store.refresh(trigger: .manual)

        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.primaryBucket == 10)
        #expect(state.displayText == "C 10%")
    }

    @Test
    func `single enabled provider keeps the prefix-free legacy text`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-icon-single-claude",
            fetch: { _, _ in makeUsageSnapshot(primaryUsedPercent: 40) })
        ts.settings.menuBarDisplayMode = .percent
        await ts.store.refresh(trigger: .manual)

        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.displayText == "60%") // exactly today's format — no prefix
    }

    @Test
    func `forced provider setting pins icon and text together`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-icon-forced",
            codexFetch: { makeCodexSnapshot(primaryUsedPercent: 81, secondaryUsedPercent: nil) },
            fetch: { _, _ in makeUsageSnapshot(primaryUsedPercent: 40) })
        ts.settings.codexProviderEnabled = true
        ts.settings.menuBarDisplayMode = .percent
        ts.settings.menuBarProviderSource = .claude
        await ts.store.refresh(trigger: .manual)

        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.primaryBucket == 60) // claude pinned despite codex being more constrained
        #expect(state.displayText == "C 60%")
    }

    @Test
    func `codex auth problems dim the icon when codex is the winner`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-icon-codex-auth",
            codexFetch: { throw CodexUsageError.unauthorized },
            fetch: { _, _ in makeUsageSnapshot(primaryUsedPercent: 40) })
        ts.settings.claudeProviderEnabled = false
        ts.settings.codexProviderEnabled = true
        await ts.store.refresh(trigger: .manual)

        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.needsAuth)
        #expect(!state.credentialsMissing)
        #expect(state.rendererKey.dimmed)

        // credentialsMissing maps to the credentials treatment, not needsAuth.
        let ts2 = makeTestStore(
            suiteName: "sturtbar-icon-codex-creds",
            codexFetch: { throw CodexUsageError.credentialsMissing },
            fetch: { _, _ in makeUsageSnapshot() })
        ts2.settings.claudeProviderEnabled = false
        ts2.settings.codexProviderEnabled = true
        await ts2.store.refresh(trigger: .manual)
        let state2 = IconState.derive(store: ts2.store, settings: ts2.settings)
        #expect(state2.credentialsMissing)
        #expect(!state2.needsAuth)
    }

    @Test
    func `both providers off derives a neutral undimmed empty icon`() {
        let ts = makeTestStore(
            suiteName: "sturtbar-icon-none",
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.claudeProviderEnabled = false
        ts.settings.menuBarDisplayMode = .percent

        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.primaryBucket == nil)
        #expect(state.secondaryBucket == nil)
        #expect(state.displayText == nil)
        #expect(!state.rendererKey.dimmed)
    }

    @Test
    func `toggling codex changes the derived state`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-icon-toggle",
            codexFetch: { makeCodexSnapshot(primaryUsedPercent: 81, secondaryUsedPercent: nil) },
            fetch: { _, _ in makeUsageSnapshot(primaryUsedPercent: 40) })
        ts.settings.menuBarDisplayMode = .percent
        await ts.store.refresh(trigger: .manual)

        let before = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(before.displayText == "60%")

        ts.settings.codexProviderEnabled = true
        ts.store.providerEnabledDidChange(.codex, enabled: true)
        for _ in 0..<2000 {
            if ts.store.codexUsage != nil { break }
            await Task.yield()
        }

        let after = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(after.displayText == "X 19%")
    }
}
