// UpdateStoreTests.swift — the update lane's state machine: offers, persistence, the hard
// privacy gate, manual-check consent semantics, and the menu item presentation.

import Foundation
import SturtBarCore
import Testing
@testable import SturtBar

private struct ScriptedChecker: UpdateChecking {
    let handler: @Sendable (String?) async throws -> LatestReleaseResponse

    func fetchLatestRelease(etag: String?) async throws -> LatestReleaseResponse {
        try await self.handler(etag)
    }
}

private func makeRelease(_ version: String) -> ReleaseInfo {
    ReleaseInfo(
        version: SemanticVersion(string: version)!,
        tagName: "v\(version)",
        zipAssetURL: URL(string: "https://example.com/SturtBar-\(version).zip")!,
        zipAssetName: "SturtBar-\(version).zip",
        zipAssetSize: 100,
        zipAssetDigest: nil,
        checksumAssetURL: URL(string: "https://example.com/SturtBar-\(version).zip.sha256")!,
        notes: nil)
}

@MainActor
struct UpdateStoreTests {
    private func makeDefaults(_ suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(
        suiteName: String,
        enabled: Bool?,
        currentVersion: String? = "1.2.0",
        handler: @escaping @Sendable (String?) async throws -> LatestReleaseResponse)
        -> (store: UpdateStore, defaults: UserDefaults)
    {
        let defaults = self.makeDefaults(suiteName)
        let settings = SettingsStore(userDefaults: defaults)
        settings.updateChecksEnabled = enabled
        let store = UpdateStore(
            settings: settings,
            checker: ScriptedChecker(handler: handler),
            userDefaults: defaults,
            currentVersion: currentVersion.flatMap(SemanticVersion.init(string:)),
            now: { Date(timeIntervalSince1970: 1_000_000) })
        return (store, defaults)
    }

    @Test
    func `a newer release becomes the standing offer and persists`() async {
        let (store, defaults) = self.makeStore(suiteName: "sturtbar-update-offer", enabled: true) { _ in
            .release(makeRelease("9.9.9"), etag: "\"e1\"")
        }
        let outcome = await store.performCheck(userInitiated: false)
        #expect(outcome == .available(makeRelease("9.9.9")))
        #expect(store.availableRelease == makeRelease("9.9.9"))
        #expect(store.lastCheckedAt != nil)
        #expect(defaults.string(forKey: "sturtbar.updateETag") == "\"e1\"")
        #expect(defaults.data(forKey: "sturtbar.updateAvailableRelease") != nil)
        #expect(defaults.object(forKey: "sturtbar.updateLastCheckedAt") != nil)
    }

    @Test
    func `an equal or older release is never offered`() async {
        let (store, defaults) = self.makeStore(suiteName: "sturtbar-update-downgrade", enabled: true) { _ in
            .release(makeRelease("1.2.0"), etag: nil)
        }
        let outcome = await store.performCheck(userInitiated: false)
        #expect(outcome == .upToDate)
        #expect(store.availableRelease == nil)
        #expect(defaults.data(forKey: "sturtbar.updateAvailableRelease") == nil)
    }

    @Test
    func `a manual check with the gate off persists nothing`() async {
        let (store, defaults) = self.makeStore(suiteName: "sturtbar-update-gate-off", enabled: nil) { etag in
            #expect(etag == nil) // no stored ETag may be sent while the gate is off
            return .release(makeRelease("9.9.9"), etag: "\"e1\"")
        }
        let outcome = await store.performCheck(userInitiated: true)
        #expect(outcome == .available(makeRelease("9.9.9")))
        #expect(store.availableRelease == makeRelease("9.9.9")) // in-memory offer only
        #expect(defaults.string(forKey: "sturtbar.updateETag") == nil)
        #expect(defaults.data(forKey: "sturtbar.updateAvailableRelease") == nil)
        #expect(defaults.object(forKey: "sturtbar.updateLastCheckedAt") == nil)
    }

    @Test
    func `disabling wipes the lane's persisted state`() async {
        let (store, defaults) = self.makeStore(suiteName: "sturtbar-update-wipe", enabled: true) { _ in
            .release(makeRelease("9.9.9"), etag: "\"e1\"")
        }
        await store.performCheck(userInitiated: false)
        #expect(defaults.data(forKey: "sturtbar.updateAvailableRelease") != nil)

        store.updateChecksEnabledDidChange(false)
        #expect(store.availableRelease == nil)
        #expect(store.lastCheckedAt == nil)
        #expect(defaults.string(forKey: "sturtbar.updateETag") == nil)
        #expect(defaults.data(forKey: "sturtbar.updateAvailableRelease") == nil)
        #expect(defaults.object(forKey: "sturtbar.updateLastCheckedAt") == nil)
    }

    @Test
    func `a 304 keeps the standing offer and reuses the stored ETag`() async {
        let (store, _) = self.makeStore(suiteName: "sturtbar-update-etag", enabled: true) { etag in
            if etag == nil {
                return .release(makeRelease("9.9.9"), etag: "\"e1\"")
            }
            #expect(etag == "\"e1\"")
            return .notModified
        }
        await store.performCheck(userInitiated: false)
        let second = await store.performCheck(userInitiated: false)
        #expect(second == .available(makeRelease("9.9.9")))
        #expect(store.availableRelease == makeRelease("9.9.9"))
    }

    @Test
    func `failures map to typed outcomes and still stamp the attempt`() async {
        let (offline, _) = self.makeStore(suiteName: "sturtbar-update-offline", enabled: true) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(await offline.performCheck(userInitiated: true) == .failed(.offline))
        #expect(offline.lastCheckedAt != nil) // backs off to the daily cadence, no minute-loop

        let (limited, _) = self.makeStore(suiteName: "sturtbar-update-limited", enabled: true) { _ in
            throw GitHubReleaseClient.Error.rateLimited
        }
        #expect(await limited.performCheck(userInitiated: true) == .failed(.rateLimited))

        let (bad, _) = self.makeStore(suiteName: "sturtbar-update-bad", enabled: true) { _ in
            throw GitHubReleaseClient.Error.invalidJSON
        }
        #expect(await bad.performCheck(userInitiated: true) == .failed(.badResponse))
    }

    @Test
    func `a persisted offer survives restart only while it is still newer`() throws {
        let suiteName = "sturtbar-update-restart"
        let defaults = self.makeDefaults(suiteName)
        let settings = SettingsStore(userDefaults: defaults)
        settings.updateChecksEnabled = true
        let data = try JSONEncoder().encode(makeRelease("9.9.9"))
        defaults.set(data, forKey: "sturtbar.updateAvailableRelease")

        let stillNewer = UpdateStore(
            settings: settings,
            checker: ScriptedChecker { _ in .notModified },
            userDefaults: defaults,
            currentVersion: SemanticVersion(string: "1.2.0"))
        #expect(stillNewer.availableRelease == makeRelease("9.9.9"))

        let alreadyInstalled = UpdateStore(
            settings: settings,
            checker: ScriptedChecker { _ in .notModified },
            userDefaults: defaults,
            currentVersion: SemanticVersion(string: "9.9.9"))
        #expect(alreadyInstalled.availableRelease == nil)
        #expect(defaults.data(forKey: "sturtbar.updateAvailableRelease") == nil)
    }

    @Test
    func `dev builds never offer updates`() async {
        let (store, _) = self.makeStore(
            suiteName: "sturtbar-update-dev",
            enabled: true,
            currentVersion: nil)
        { _ in
            .release(makeRelease("9.9.9"), etag: nil)
        }
        #expect(await store.performCheck(userInitiated: true) == .upToDate)
        #expect(store.availableRelease == nil)
    }
}

@MainActor
struct UpdateMenuPresentationTests {
    @Test
    func `the one item morphs across phases and offers`() {
        let offered = SemanticVersion(string: "9.9.9")
        #expect(UpdateMenuPresentation.item(phase: .idle, availableVersion: nil)
            == UpdateMenuPresentation.Item(title: "Check for Updates…", enabled: true))
        #expect(UpdateMenuPresentation.item(phase: .idle, availableVersion: offered)
            == UpdateMenuPresentation.Item(title: "Install Update 9.9.9…", enabled: true))
        #expect(UpdateMenuPresentation.item(phase: .checking, availableVersion: nil)
            == UpdateMenuPresentation.Item(title: "Checking for Updates…", enabled: false))
        #expect(UpdateMenuPresentation.item(phase: .downloading, availableVersion: offered)
            == UpdateMenuPresentation.Item(title: "Downloading Update…", enabled: false))
        #expect(UpdateMenuPresentation.item(phase: .installing, availableVersion: offered)
            == UpdateMenuPresentation.Item(title: "Installing Update…", enabled: false))
    }
}

@MainActor
struct UpdateChecksSettingTests {
    @Test
    func `the setting defaults to undecided and round-trips decisions`() throws {
        let suiteName = "sturtbar-settings-update-checks"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(userDefaults: defaults)
        #expect(settings.updateChecksEnabled == nil)

        var observed: [Bool?] = []
        settings.onUpdateChecksEnabledChange = { observed.append($0) }
        settings.updateChecksEnabled = true
        #expect(SettingsStore(userDefaults: defaults).updateChecksEnabled == true)
        settings.updateChecksEnabled = false
        #expect(SettingsStore(userDefaults: defaults).updateChecksEnabled == false)
        #expect(observed == [true, false])
    }
}
