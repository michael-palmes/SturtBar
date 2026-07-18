// UpdateStore.swift: update-check state machine, daily scheduling and the hard privacy gate.
//
// Privacy contract (mirrors the provider lanes): while the gate is off or undecided there is no
// network, no timer and no persisted trace, and disabling wipes the lane's stored state. The
// manual menu action is explicit user consent and may run a single check while the daily gate is
// off; such a check persists nothing. Background failures are silent (log only); only manual
// checks surface errors. Errors are typed end to end, never string-matched.

import AppKit
import Foundation
import Observation
import SturtBarCore

@MainActor
@Observable
final class UpdateStore {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
    }

    enum UpdateFailure: Equatable {
        case offline
        case rateLimited
        case badResponse

        var userMessage: String {
            switch self {
            case .offline: "The update check could not reach GitHub. Check your connection and try again."
            case .rateLimited: "GitHub is limiting requests from this network. Try again later."
            case .badResponse: "GitHub returned an unexpected response. Try again later."
            }
        }
    }

    enum ManualCheckOutcome: Equatable {
        case upToDate
        case available(ReleaseInfo)
        case failed(UpdateFailure)
        case busy
    }

    enum InstallFlowResult: Equatable {
        case installedAndReadyToRelaunch
        case revealed(reason: UpdateRevealReason, appURL: URL)
        case failed(UpdateInstallError)
        case busy
        case nothingToInstall
    }

    private enum Keys {
        static let lastCheckedAt = "sturtbar.updateLastCheckedAt"
        static let etag = "sturtbar.updateETag"
        static let availableRelease = "sturtbar.updateAvailableRelease"
    }

    private(set) var phase: Phase = .idle
    /// The newer-than-running release on offer; drives the menu's "Install Update" morph.
    private(set) var availableRelease: ReleaseInfo?
    private(set) var lastCheckedAt: Date?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let checker: any UpdateChecking
    @ObservationIgnored private let installer: (any UpdateInstalling)?
    /// nil under `swift run` ("dev"): dev builds never offer or install updates.
    @ObservationIgnored private let currentVersion: SemanticVersion?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    private static let log = SturtBarLog.logger("updater")

    init(
        settings: SettingsStore,
        checker: any UpdateChecking,
        installer: (any UpdateInstalling)? = nil,
        userDefaults: UserDefaults = .standard,
        currentVersion: SemanticVersion? = UpdateStore.bundleVersion(),
        now: @escaping () -> Date = Date.init)
    {
        self.settings = settings
        self.checker = checker
        self.installer = installer
        self.defaults = userDefaults
        self.currentVersion = currentVersion
        self.now = now
        self.lastCheckedAt = userDefaults.object(forKey: Keys.lastCheckedAt) as? Date
        // A persisted offer only survives if it is still newer than the running version.
        self.availableRelease = Self.loadPersistedRelease(defaults: userDefaults, newerThan: currentVersion)
        if self.availableRelease == nil {
            userDefaults.removeObject(forKey: Keys.availableRelease)
            // No standing offer means no reason to keep any staged download around.
            if installer != nil {
                UpdateInstaller.removeStagedUpdates()
            }
        }
    }

    nonisolated static func bundleVersion() -> SemanticVersion? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        return SemanticVersion(string: raw)
    }

    // MARK: - Lifecycle

    /// Called once from the deferred launch task: observes wake and arms the daily loop.
    func start() {
        guard self.wakeObserver == nil else { return }
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            // A lid-closed overnight sleep can carry the loop past its due time; re-evaluate soon.
            Task { @MainActor [weak self] in
                self?.armSchedule(initialDelay: 30)
            }
        }
        self.armSchedule(initialDelay: 60)
    }

    func shutdown() {
        self.scheduleTask?.cancel()
        self.scheduleTask = nil
        if let observer = self.wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.wakeObserver = nil
        }
    }

    /// Settings wiring: enabling arms the loop (first check runs almost immediately when never
    /// checked); disabling or resetting to undecided cancels it and wipes every persisted trace.
    func updateChecksEnabledDidChange(_ enabled: Bool?) {
        if enabled == true {
            self.armSchedule(initialDelay: 2)
        } else {
            self.scheduleTask?.cancel()
            self.scheduleTask = nil
            self.defaults.removeObject(forKey: Keys.lastCheckedAt)
            self.defaults.removeObject(forKey: Keys.etag)
            self.defaults.removeObject(forKey: Keys.availableRelease)
            self.lastCheckedAt = nil
            self.availableRelease = nil
            if self.installer != nil {
                UpdateInstaller.removeStagedUpdates()
            }
        }
    }

    // MARK: - Scheduling

    /// Sleep-first loop: wakes, checks if due (the policy gates on the enabled flag every pass),
    /// then sleeps until the next due time. Holds the store weakly across the long sleeps.
    private func armSchedule(initialDelay: TimeInterval) {
        self.scheduleTask?.cancel()
        guard self.settings.updateChecksEnabled == true else { return }
        self.scheduleTask = Task { [weak self] in
            var delay = initialDelay
            while true {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                guard let store = self else { return }
                if UpdateCheckPolicy.shouldCheck(
                    now: store.now(),
                    lastCheckedAt: store.lastCheckedAt,
                    enabled: store.settings.updateChecksEnabled == true)
                {
                    await store.performCheck(userInitiated: false)
                }
                delay = UpdateCheckPolicy.nextCheckDelay(now: store.now(), lastCheckedAt: store.lastCheckedAt)
            }
        }
    }

    // MARK: - Checking

    /// One metadata-only check. Failures also stamp lastCheckedAt so an offline loop backs off
    /// to the daily cadence instead of retrying every minute.
    @discardableResult
    func performCheck(userInitiated: Bool) async -> ManualCheckOutcome {
        guard self.phase == .idle else { return .busy }
        self.phase = .checking
        let attemptAt = self.now()
        defer {
            self.recordCheck(at: attemptAt)
            self.phase = .idle
        }

        // Manual checks with the daily gate off skip the stored ETag so they persist nothing.
        let etag = self.settings.updateChecksEnabled == true ? self.defaults.string(forKey: Keys.etag) : nil
        do {
            let response = try await self.checker.fetchLatestRelease(etag: etag)
            switch response {
            case .notModified:
                // Same release as last seen; any standing offer stands.
                break
            case let .release(info, etag: newETag):
                if self.settings.updateChecksEnabled == true, let newETag {
                    self.defaults.set(newETag, forKey: Keys.etag)
                }
                self.apply(release: info)
            }
            if let release = self.availableRelease {
                Self.log.info("Update available", metadata: ["version": "\(release.version)"])
                return .available(release)
            }
            return .upToDate
        } catch {
            let failure = Self.failure(for: error)
            Self.log.warning(
                "Update check failed",
                metadata: ["reason": "\(failure)", "userInitiated": "\(userInitiated)"])
            return .failed(failure)
        }
    }

    private func recordCheck(at date: Date) {
        self.lastCheckedAt = date
        if self.settings.updateChecksEnabled == true {
            self.defaults.set(date, forKey: Keys.lastCheckedAt)
        }
    }

    /// Downgrade guard lives here: only strictly newer than the running version is ever offered.
    private func apply(release: ReleaseInfo) {
        guard let current = self.currentVersion, release.version > current else {
            self.availableRelease = nil
            self.defaults.removeObject(forKey: Keys.availableRelease)
            return
        }
        self.availableRelease = release
        if self.settings.updateChecksEnabled == true, let data = try? JSONEncoder().encode(release) {
            self.defaults.set(data, forKey: Keys.availableRelease)
        }
    }

    private static func failure(for error: any Error) -> UpdateFailure {
        switch error {
        case GitHubReleaseClient.Error.rateLimited:
            .rateLimited
        case is GitHubReleaseClient.Error:
            .badResponse
        case is URLError:
            .offline
        default:
            .badResponse
        }
    }

    private static func loadPersistedRelease(
        defaults: UserDefaults,
        newerThan current: SemanticVersion?) -> ReleaseInfo?
    {
        guard let data = defaults.data(forKey: Keys.availableRelease),
              let release = try? JSONDecoder().decode(ReleaseInfo.self, from: data),
              let current, release.version > current
        else { return nil }
        return release
    }

    // MARK: - Installing

    /// Runs the download-verify-swap flow for the standing offer. On success the caller (menu)
    /// terminates the app; the installer has already spawned the relaunch helper. On reveal or
    /// failure the offer stands so the menu keeps its retry affordance.
    func installAvailableUpdate() async -> InstallFlowResult {
        guard let installer = self.installer, let release = self.availableRelease else {
            return .nothingToInstall
        }
        guard self.phase == .idle else { return .busy }
        self.phase = .downloading
        defer {
            if self.availableRelease != nil {
                self.phase = .idle
            }
        }

        let result = await installer.install(release: release) { [weak self] stage in
            Task { @MainActor [weak self] in
                guard let self, self.phase != .idle else { return }
                self.phase = stage == .installing ? .installing : .downloading
            }
        }
        switch result {
        case .installed:
            self.availableRelease = nil
            self.defaults.removeObject(forKey: Keys.availableRelease)
            self.phase = .idle
            Self.log.info("Update installed", metadata: ["version": "\(release.version)"])
            return .installedAndReadyToRelaunch
        case let .revealedForManualInstall(reason, appURL):
            Self.log.info("Update revealed for manual install", metadata: ["reason": "\(reason)"])
            return .revealed(reason: reason, appURL: appURL)
        case let .failed(error):
            Self.log.error("Update install failed", metadata: ["reason": "\(error)"])
            return .failed(error)
        }
    }
}
