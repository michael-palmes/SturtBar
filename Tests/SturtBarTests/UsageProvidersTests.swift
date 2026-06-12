// UsageProvidersTests.swift — provider vocabulary + provider-enable settings.
//
// The settings tests pin the opt-in contract: Claude defaults ON, Codex defaults OFF, and a
// fresh install (absent keys) reproduces today's Claude-only behavior exactly.

import Foundation
import Testing
@testable import SturtBar

struct UsageProviderKindTests {
    @Test
    func `provider order and identity are stable`() {
        #expect(UsageProviderKind.allCases == [.claude, .codex])
        #expect(UsageProviderKind.claude.displayName == "Claude")
        #expect(UsageProviderKind.codex.displayName == "Codex")
        #expect(UsageProviderKind.claude.menuBarPrefix == "C")
        #expect(UsageProviderKind.codex.menuBarPrefix == "X")
    }

    @Test
    func `menu bar provider source round-trips and defaults to auto`() {
        #expect(MenuBarProviderSource.default == .auto)
        for source in MenuBarProviderSource.allCases {
            #expect(MenuBarProviderSource(rawValue: source.rawValue) == source)
        }
        #expect(MenuBarProviderSource.allCases.count == 3)
    }
}

@MainActor
struct ProviderSettingsTests {
    @Test
    func `fresh install defaults to Claude on and Codex off`() {
        let settings = makeTestSettings(suiteName: "sturtbar-provider-defaults")
        #expect(settings.claudeProviderEnabled)
        #expect(!settings.codexProviderEnabled)
        #expect(settings.menuBarProviderSource == .auto)
        #expect(settings.enabledProviders == [.claude])
    }

    @Test
    func `provider toggles persist across store instances`() throws {
        let suiteName = "sturtbar-provider-roundtrip"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let first = SettingsStore(userDefaults: defaults)
        first.codexProviderEnabled = true
        first.claudeProviderEnabled = false
        first.menuBarProviderSource = .codex

        let second = SettingsStore(userDefaults: defaults)
        #expect(second.codexProviderEnabled)
        #expect(!second.claudeProviderEnabled)
        #expect(second.menuBarProviderSource == .codex)
        #expect(second.enabledProviders == [.codex])
    }

    @Test
    func `enabledProviders follows declaration order`() {
        let settings = makeTestSettings(suiteName: "sturtbar-provider-order")
        settings.codexProviderEnabled = true
        #expect(settings.enabledProviders == [.claude, .codex])

        settings.claudeProviderEnabled = false
        settings.codexProviderEnabled = false
        #expect(settings.enabledProviders.isEmpty)
    }

    @Test
    func `provider toggle fires the change callback once per flip`() {
        let settings = makeTestSettings(suiteName: "sturtbar-provider-callback")
        var events: [(UsageProviderKind, Bool)] = []
        settings.onProviderEnabledChange = { events.append(($0, $1)) }

        settings.codexProviderEnabled = true
        settings.codexProviderEnabled = true // same value: no event
        settings.claudeProviderEnabled = false

        #expect(events.count == 2)
        #expect(events[0] == (.codex, true))
        #expect(events[1] == (.claude, false))
    }

    @Test
    func `provider enabled accessor matches the per-provider properties`() {
        let settings = makeTestSettings(suiteName: "sturtbar-provider-accessor")
        settings.codexProviderEnabled = true
        #expect(settings.providerEnabled(.claude))
        #expect(settings.providerEnabled(.codex))
        settings.claudeProviderEnabled = false
        #expect(!settings.providerEnabled(.claude))
    }
}
