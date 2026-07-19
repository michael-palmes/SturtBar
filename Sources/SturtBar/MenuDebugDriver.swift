// MenuDebugDriver.swift — DEBUG-only, env-gated live-verification driver (Phase 4b).
//
// `STURTBAR_DEBUG_AUTOMENU=1 swift run SturtBar` exercises the menu without UI scripting (which
// is TCC-gated): it opens the status-item menu after a delay, holds it open across TimelineView
// tick boundaries, fires a mid-open manual refresh, closes, then watches an idle window —
// emitting log markers so `log stream` shows:
//   (a) per-minute card content renders while the menu is open,
//   (b) zero renders of the retained hosting view after close,
//   (e) the mid-open model re-make path (refresh lands → rootView swap, no re-measure).
//
// Run-loop discipline (the part that makes this equivalent to a real click): `performClick`
// runs the menu-tracking loop synchronously, so it MUST NOT be called from a MainActor task —
// that would enter tracking from inside a main-queue drain, and the queue cannot drain
// re-entrantly, freezing every queued MainActor continuation until the menu closes (including
// the refresh the menu open itself schedules). A real click enters tracking from the run-loop
// event phase, where queued main-actor work continues to interleave. Timers scheduled in
// `.common` modes reproduce that: the open fires from a timer callout (not a queue drain), and
// the probe/close timers fire inside the nested tracking loop. Production builds compile this
// file out; normal DEBUG runs skip it unless the env var is set.

#if DEBUG
import AppKit
import Foundation
import SturtBarCore

@MainActor
final class MenuDebugDriver {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["STURTBAR_DEBUG_AUTOMENU"] == "1"
    }

    private static let log = SturtBarLog.logger("debug-automenu")

    private let controller: StatusItemController
    private let store: UsageStore
    private var timers: [Timer] = []

    init(controller: StatusItemController, store: UsageStore) {
        self.controller = controller
        self.store = store
    }

    func start() {
        let openDelay: TimeInterval = 5
        let probeDelay: TimeInterval = 10
        let holdDuration: TimeInterval = 80 // > one 60s TimelineView tick
        let idleWatch: TimeInterval = 150 // > two would-be ticks while closed

        self.schedule(after: openDelay) { driver in
            let preOpenRenders = MenuCardRenderProbe.renderCount
            Self.log.info("AUTOMENU open", metadata: ["preOpenRenders": "\(preOpenRenders)"])

            // Scheduled before tracking starts; .common-mode timers fire inside it.
            driver.schedule(after: probeDelay) { probeDriver in
                Self.log.info("AUTOMENU mid-open manual refresh")
                let store = probeDriver.store
                Task { @MainActor in
                    await store.refresh(trigger: .manual)
                    Self.log.info(
                        "AUTOMENU mid-open refresh done",
                        metadata: ["renders": "\(MenuCardRenderProbe.renderCount)"])
                }
            }
            // (c) probe — KNOWN LIMITATION: events posted via NSApp.postEvent reach the menu
            // tracking session at the queue level (it dismisses on the posted up) but are NOT
            // routed into item views the way window-server clicks are, so the card view's
            // consume-loop never engages for synthetic clicks and this probe reports FAIL even
            // though real clicks dispatch into views (legacy CodexBar's clickable rows + this
            // same overlay shipped working). Kept for documentation; confirm with one human
            // click on the card: the menu must stay open.
            driver.schedule(after: probeDelay + 5) { clickDriver in
                clickDriver.postClickOnCard()
            }
            driver.schedule(after: probeDelay + 8) { verifyDriver in
                let stillOpen = verifyDriver.controller.menuIsOpen
                Self.log.info(
                    "AUTOMENU card click probe (synthetic-only; see driver comment)",
                    metadata: ["menuStillOpen": "\(stillOpen)"])
            }
            driver.schedule(after: holdDuration) { closeDriver in
                Self.log.info("AUTOMENU closing menu (safety)")
                closeDriver.controller.menu?.cancelTracking()
            }

            driver.controller.statusItem?.button?.performClick(nil) // blocks until menu closes

            let closedRenders = MenuCardRenderProbe.renderCount
            Self.log.info(
                "AUTOMENU menu closed",
                metadata: [
                    "rendersWhileOpen": "\(closedRenders - preOpenRenders)",
                    "totalRenders": "\(closedRenders)",
                ])

            driver.schedule(after: 2) { chartDriver in
                chartDriver.runChartHoverPhase()
            }
            driver.schedule(after: 8) { windowsDriver in
                windowsDriver.runWindowsPhase()
            }

            driver.schedule(after: 12) { idleDriver in
                let idleBaseline = MenuCardRenderProbe.renderCount
                idleDriver.schedule(after: idleWatch) { _ in
                    let idleRenders = MenuCardRenderProbe.renderCount - idleBaseline
                    Self.log.info(
                        "AUTOMENU idle check",
                        metadata: [
                            "rendersWhileClosed": "\(idleRenders)",
                            "verdict": idleRenders == 0 ? "PASS (timeline idle when closed)" : "FAIL",
                        ])
                }
            }
        }
    }

    // MARK: - Phases

    /// (c) Posts leftMouseDown/Up at the center of the hosted card inside the open menu window.
    private func postClickOnCard() {
        guard let cardView = self.controller.claudeCardSlot?.hostingView, let window = cardView.window else {
            Self.log.error("AUTOMENU card click: card view is not in a window")
            return
        }
        let centerInWindow = cardView.convert(NSPoint(x: cardView.bounds.midX, y: cardView.bounds.midY), to: nil)
        Self.log.info(
            "AUTOMENU posting card click",
            metadata: ["windowNumber": "\(window.windowNumber)", "location": "\(centerInWindow)"])
        self.postMouseClick(at: centerInWindow, windowNumber: window.windowNumber)
    }

    /// (d) Pops the chart submenu up as a standalone menu (same hosting context as the hover
    /// case: a real NSMenu window), then drives MouseLocationReader with mouseMoved events.
    private func runChartHoverPhase() {
        guard let submenu = self.controller.chartItem?.submenu else {
            Self.log.error("AUTOMENU chart hover: no chart submenu (cost disabled?)")
            return
        }
        self.controller.hydrateChartSubmenu(submenu)
        guard let chartView = self.controller.chartHostingView else {
            Self.log.warning("AUTOMENU chart hover: no chart hosting view (no cost data)")
            return
        }

        self.schedule(after: 1.5) { driver in
            guard let window = chartView.window,
                  let trackingView = Self.findTrackingView(in: chartView)
            else {
                Self.log.error(
                    "AUTOMENU chart hover: chart not in a window or no tracking view",
                    metadata: ["inWindow": "\(chartView.window != nil)"])
                driver.controller.chartItem?.submenu?.cancelTracking()
                return
            }
            Self.log.info(
                "AUTOMENU chart hover setup",
                metadata: [
                    "windowAcceptsMouseMoved": "\(window.acceptsMouseMovedEvents)",
                    "trackingAreas": "\(trackingView.trackingAreas.count)",
                ])
            // Sweep three x positions across the plot. Tracking-area mouseMoved events are
            // generated from the real cursor by AppKit, so they cannot be synthesized through
            // the queue without TCC; dispatching to the tracking view directly exercises the
            // identical handler path (onMoved → chart selection → re-render) in the REAL menu
            // window. The residual gap (window-server delivery into .activeAlways areas) is
            // the legacy-ported MouseLocationReader's proven behavior.
            for fraction in [0.2, 0.5, 0.8] {
                let local = NSPoint(x: trackingView.bounds.width * fraction, y: trackingView.bounds.height / 2)
                let inWindow = trackingView.convert(local, to: nil)
                if let event = NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: inWindow,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 0,
                    pressure: 0)
                {
                    trackingView.mouseMoved(with: event)
                }
            }
            driver.schedule(after: 1) { closeDriver in
                closeDriver.controller.chartItem?.submenu?.cancelTracking()
            }
        }

        Self.log.info("AUTOMENU popping chart submenu standalone")
        submenu.popUp(positioning: nil, at: NSPoint(x: 300, y: 300), in: nil) // blocks while open
        Self.log.info("AUTOMENU chart submenu closed")
    }

    /// Settings/About windows: lazy creation, activation, reuse across close.
    private func runWindowsPhase() {
        guard let windows = self.controller.windows else {
            Self.log.error("AUTOMENU windows phase: no WindowsController")
            return
        }
        windows.showSettings()
        let settings = windows.settingsWindow
        let settingsShown = settings?.isVisible ?? false
        settings?.close()
        windows.showSettings()
        let reused = windows.settingsWindow === settings
        let reshown = windows.settingsWindow?.isVisible ?? false
        windows.settingsWindow?.close()

        windows.showAbout()
        let aboutShown = windows.aboutWindow?.isVisible ?? false
        windows.aboutWindow?.close()

        Self.log.info(
            "AUTOMENU windows verdict",
            metadata: [
                "settingsShown": "\(settingsShown)",
                "settingsFrame": "\(settings?.frame ?? .zero)",
                "reusedAfterClose": "\(reused)",
                "reshown": "\(reshown)",
                "aboutShown": "\(aboutShown)",
                "verdict": settingsShown && reused && reshown && aboutShown ? "PASS" : "FAIL",
            ])
    }

    private func postMouseClick(at locationInWindow: NSPoint, windowNumber: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type,
                location: locationInWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1)
            {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func findTrackingView(in root: NSView) -> NSView? {
        if root is MouseLocationReader.TrackingView { return root }
        for subview in root.subviews {
            if let found = findTrackingView(in: subview) { return found }
        }
        return nil
    }

    /// Common-modes timer → fires during menu tracking; callout runs on the main thread outside
    /// any main-queue drain (Timer tolerates the nonisolated closure; hop via assumeIsolated).
    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor (MenuDebugDriver) -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timers.append(timer)
    }
}
#endif
