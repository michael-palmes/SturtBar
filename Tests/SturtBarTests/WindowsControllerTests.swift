// WindowsControllerTests.swift — lazy creation + reuse of the Settings/About windows (Phase 4b).
//
// Headless-safety: WindowsController skips `NSApp.activate` / `makeKeyAndOrderFront` under test
// processes (ProcessEnvironment.isRunningTests), so these tests only exercise window CREATION
// and identity reuse — NSWindow construction without ordering-on-screen is CI-safe. Actual
// presentation (activation, key status, close-button reuse) is verified live; see the Phase 4b
// verification notes. AboutView.versionString is pure and covered below for the `swift run`
// nil-Info.plist fallback.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SturtBar

@MainActor
struct WindowsControllerTests {
    private func makeController(_ suiteName: String) -> WindowsController {
        WindowsController(settings: makeTestSettings(suiteName: suiteName))
    }

    @Test
    func `windows are created lazily`() {
        let windows = self.makeController("sturtbar-windows-lazy")
        #expect(windows.settingsWindow == nil)
        #expect(windows.aboutWindow == nil)

        windows.showSettings()
        #expect(windows.settingsWindow != nil)
        #expect(windows.aboutWindow == nil) // showing one never creates the other
    }

    @Test
    func `settings window is reused across show and close`() throws {
        let windows = self.makeController("sturtbar-windows-reuse")
        windows.showSettings()
        let first = try #require(windows.settingsWindow)
        #expect(!first.isReleasedWhenClosed) // close hides; the controller keeps the reference

        first.close()
        windows.showSettings()
        #expect(windows.settingsWindow === first) // same instance — no window leak per open/close
    }

    @Test
    func `about window is reused and independent of settings`() throws {
        let windows = self.makeController("sturtbar-windows-about")
        windows.showAbout()
        let about = try #require(windows.aboutWindow)
        #expect(about.title == "About SturtBar")
        #expect(!about.isReleasedWhenClosed)

        about.close()
        windows.showAbout()
        #expect(windows.aboutWindow === about)
        #expect(windows.settingsWindow == nil)
    }

    @Test
    func `settings window opens with a non-degenerate frame`() throws {
        let windows = self.makeController("sturtbar-windows-frame")
        windows.showSettings()
        let window = try #require(windows.settingsWindow)
        let hosting = try #require(window.contentViewController as? NSHostingController<SettingsView>)
        // A height-flexible root (macOS TabView) measures degenerate or greedy here and the
        // window never appears on screen.
        let natural = hosting.sizeThatFits(in: CGSize(width: 10000, height: 10000))
        #expect(natural.width > 300 && natural.width < 1000)
        #expect(natural.height > 200 && natural.height < 1500)
        // Headless windows never lay out, so drive the resize path directly.
        windows.resizeSettingsWindow(to: natural)
        #expect(window.frame.width > 300)
        #expect(window.frame.height > 200)
    }

    @Test
    func `settings window carries the expected chrome`() throws {
        let windows = self.makeController("sturtbar-windows-chrome")
        windows.showSettings()
        let window = try #require(windows.settingsWindow)
        #expect(window.title == "SturtBar Settings")
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.resizable)) // content-sized single pane
    }
}

// MARK: - AboutView.versionString

struct AboutVersionStringTests {
    @Test
    func `version string falls back to dev under swift run`() {
        #expect(AboutView.versionString(version: nil, build: nil) == "dev")
        #expect(AboutView.versionString(version: "", build: "7") == "dev")
        #expect(AboutView.versionString(version: "1.2", build: nil) == "1.2")
        #expect(AboutView.versionString(version: "1.2", build: "") == "1.2")
        #expect(AboutView.versionString(version: "1.2", build: "34") == "1.2 (34)")
    }
}

// MARK: - QuotaWarningThresholds.resolved (settings threshold-field commit path)

struct QuotaWarningThresholdResolutionTests {
    @Test
    func `resolved pairs follow the legacy semantics`() {
        #expect(QuotaWarningThresholds.resolved(upper: nil, lower: nil) == [50, 20])
        #expect(QuotaWarningThresholds.resolved(upper: 60, lower: 30) == [60, 30])
        #expect(QuotaWarningThresholds.resolved(upper: 60, lower: nil) == [60, 20])
        // Upper below the default lower: the missing lower becomes 0 (disabled slot).
        #expect(QuotaWarningThresholds.resolved(upper: 10, lower: nil) == [10, 0])
        #expect(QuotaWarningThresholds.resolved(upper: nil, lower: 5) == [50, 5])
        // Clamping + descending sort still apply.
        #expect(QuotaWarningThresholds.resolved(upper: 150, lower: -2) == [99, 0])
        #expect(QuotaWarningThresholds.resolved(upper: 20, lower: 80) == [80, 20])
    }
}
