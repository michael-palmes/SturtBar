// SturtBarApp.swift — app entry point and composition root.
//
// AppDelegate wires the pieces and owns nothing else:
//   - State layer (Phase 3a): SettingsStore + UsageStore (+ ClaudeUsageClient / CostScanner /
//     StatePersistence collaborators) + RefreshScheduler.
//   - Icon pipeline (Phase 3b): StatusItemController derives IconState from the stores and keeps
//     the NSStatusItem rendered; the full menu (Phase 4b) lives there too.
//   - Windows (Phase 4b): WindowsController owns the lazily-created Settings/About windows; menu
//     actions route into it.
//   - Notifications (Phase 3b): QuotaNotifier consumes the store's quota-crossing callback per
//     its contract — async dispatch only, no synchronous store mutation (posting spawns its own
//     task inside AppNotifications; nothing here re-enters refresh).
//   - Keychain prompt UX (Phase 3b): KeychainPromptCoordinator registers the core handler before
//     the first fetch could possibly preflight a keychain read.
//
// Launch stays fast: store construction is cheap (UserDefaults reads only); persisted-state load
// and the first fetch run in a utility-priority task immediately after launch.

import AppKit
import os
import SturtBarCore

@main
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore?
    private var store: UsageStore?
    private var scheduler: RefreshScheduler?
    private var statusItemController: StatusItemController?
    private var quotaNotifier: QuotaNotifier?
    private var windows: WindowsController?
    #if DEBUG
    private var menuDebugDriver: MenuDebugDriver?
    #endif

    private static let log = SturtBarLog.logger("app")
    /// MainActor-isolated (statics of a @MainActor type): set in main(), cleared at launch-complete.
    private static var launchSignpostState: OSSignpostIntervalState?

    static func main() {
        self.launchSignpostState = Signposts.launch.beginInterval("launch")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Suppress the Dock icon when launched via `swift run` (no Info.plist LSUIElement key).
        NSApp.setActivationPolicy(.accessory)

        // Gate init-ordering contract: register the credentials fingerprint provider before any
        // code consults ClaudeOAuthRefreshFailureGate.
        ClaudeOAuthCredentialsStore.ensureRefreshFailureGateFingerprintProvider()

        // Keychain prompt UX: must be installed before anything can trigger a keychain read.
        KeychainPromptCoordinator.install()

        // State layer.
        let settings = SettingsStore()
        // allowStartupBootstrapPrompt: permits the one-time background keychain prompt during the
        // startup fetch when no cached credentials exist yet (first run after install).
        let client = ClaudeUsageClient(service: ClaudeUsageService(allowStartupBootstrapPrompt: true))
        let store = UsageStore(
            settings: settings,
            client: client,
            scanner: CostScanner(),
            persistence: StatePersistence())
        let scheduler = RefreshScheduler(store: store)

        settings.onRefreshFrequencyChange = { [weak scheduler] frequency in
            scheduler?.start(interval: frequency.interval)
        }
        settings.onCostSettingsChange = { [weak store] in
            store?.costSettingsDidChange()
        }

        // Quota notifications. Contract (UsageStore.onQuotaThresholdCrossing): fires synchronously
        // on the MainActor mid-refresh; the notifier only reads settings and enqueues async
        // notification work — it never mutates store state or re-enters refresh.
        let quotaNotifier = QuotaNotifier()
        store.onQuotaThresholdCrossing = { [weak settings, weak quotaNotifier] crossing in
            guard let settings, let quotaNotifier else { return }
            quotaNotifier.post(crossing, soundEnabled: settings.quotaWarningSoundEnabled)
        }

        // Windows (Settings/About) + icon/menu pipeline.
        let windows = WindowsController(settings: settings)
        let statusItemController = StatusItemController(
            store: store,
            settings: settings,
            windows: windows,
            debugUsageClient: client)
        statusItemController.start()

        self.settings = settings
        self.store = store
        self.scheduler = scheduler
        self.statusItemController = statusItemController
        self.quotaNotifier = quotaNotifier
        self.windows = windows

        #if DEBUG
        // Live-verification driver (Phase 4b): only when STURTBAR_DEBUG_AUTOMENU=1.
        if MenuDebugDriver.isEnabled {
            let driver = MenuDebugDriver(controller: statusItemController, store: store)
            driver.start()
            self.menuDebugDriver = driver
        }
        #endif

        // Deferred launch work: cached state first, then the scheduler + startup fetch.
        Task(priority: .utility) {
            await store.loadPersistedState()
            scheduler.start(interval: settings.refreshFrequency.interval)
            await store.refresh(trigger: .launch)
        }

        // First lit 1852; standing watch since you installed it (BRAND.md §3.3 system moment).
        Self.log.info("Cape Willoughby. The light is lit; standing watch.")
        if let state = Self.launchSignpostState {
            Signposts.launch.endInterval("launch", state)
            Self.launchSignpostState = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.log.info("Dousing the light. The Passage is on its own.")
        self.statusItemController?.shutdown()
        self.store?.shutdown()
        self.scheduler?.stop()
    }
}
