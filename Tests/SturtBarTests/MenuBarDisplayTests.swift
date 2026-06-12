// MenuBarDisplayTests.swift — menu bar text mode coverage (Phase 3b).
//
// Covers the ported MenuBarDisplayText pure functions plus the trimmed Claude window resolver.

import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

struct MenuBarDisplayTests {
    private func window(usedPercent: Double, resetsAt: Date? = nil, windowMinutes: Int? = nil) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    // MARK: - percentText

    @Test
    func `percent text shows remaining by default and used on request`() {
        let window = self.window(usedPercent: 47.6)
        #expect(MenuBarDisplayText.percentText(window: window, showUsed: false) == "52%")
        #expect(MenuBarDisplayText.percentText(window: window, showUsed: true) == "48%")
        #expect(MenuBarDisplayText.percentText(window: nil, showUsed: false) == nil)
    }

    @Test
    func `percent text clamps out of range values`() {
        #expect(MenuBarDisplayText.percentText(window: self.window(usedPercent: 130), showUsed: true) == "100%")
        #expect(MenuBarDisplayText.percentText(window: self.window(usedPercent: 130), showUsed: false) == "0%")
    }

    // MARK: - paceText

    @Test
    func `pace text formats signed delta`() {
        let ahead = UsagePace.historical(
            expectedUsedPercent: 40,
            actualUsedPercent: 45,
            etaSeconds: nil,
            willLastToReset: true,
            runOutProbability: nil)
        let behind = UsagePace.historical(
            expectedUsedPercent: 40,
            actualUsedPercent: 35,
            etaSeconds: nil,
            willLastToReset: true,
            runOutProbability: nil)
        #expect(MenuBarDisplayText.paceText(pace: ahead) == "+5%")
        #expect(MenuBarDisplayText.paceText(pace: behind) == "-5%")
        #expect(MenuBarDisplayText.paceText(pace: nil) == nil)
    }

    // MARK: - displayText modes

    @Test
    func `hidden mode shows nothing`() {
        let text = MenuBarDisplayText.displayText(
            mode: .hidden,
            percentWindow: self.window(usedPercent: 20),
            pace: nil,
            showUsed: false)
        #expect(text == nil)
    }

    @Test
    func `percent mode shows percent only`() {
        let text = MenuBarDisplayText.displayText(
            mode: .percent,
            percentWindow: self.window(usedPercent: 20),
            pace: nil,
            showUsed: false)
        #expect(text == "80%")
    }

    @Test
    func `both mode joins percent and pace`() {
        let pace = UsagePace.historical(
            expectedUsedPercent: 10,
            actualUsedPercent: 20,
            etaSeconds: nil,
            willLastToReset: false,
            runOutProbability: nil)
        let text = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: self.window(usedPercent: 20),
            pace: pace,
            showUsed: false)
        #expect(text == "80% · +10%")
    }

    @Test
    func `both mode falls back to percent when pace unavailable`() {
        let text = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: self.window(usedPercent: 20),
            pace: nil,
            showUsed: false)
        #expect(text == "80%")
    }

    // MARK: - Resolver

    @Test
    func `resolver shows primary window percent`() {
        let snapshot = makeUsageSnapshot(primaryUsedPercent: 47.6)
        #expect(MenuBarMetricWindowResolver.displayText(mode: .percent, snapshot: snapshot) == "52%")
        #expect(MenuBarMetricWindowResolver.displayText(mode: .hidden, snapshot: snapshot) == nil)
        #expect(MenuBarMetricWindowResolver.displayText(mode: .percent, snapshot: nil) == nil)
    }

    @Test
    func `resolver covers spend limit primaries`() {
        // Spend-limit accounts fold the spend window into primary; the text shows its percent.
        let snapshot = makeUsageSnapshot(primaryUsedPercent: 30, primaryWindowKind: .spendLimit)
        #expect(MenuBarMetricWindowResolver.displayText(mode: .percent, snapshot: snapshot) == "70%")
    }

    @Test
    func `resolver computes pace on the percent window`() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Halfway through a 5h session window with 50% used = exactly on pace... use 60% for +10%.
        let snapshot = ProviderUsageSnapshot(
            primary: RateWindow(
                usedPercent: 60,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(150 * 60),
                resetDescription: nil),
            secondary: nil,
            opus: nil,
            updatedAt: now,
            loginMethod: nil)
        let text = MenuBarMetricWindowResolver.displayText(mode: .both, snapshot: snapshot, now: now)
        #expect(text == "40% · +10%")
        let paceOnly = MenuBarMetricWindowResolver.displayText(mode: .pace, snapshot: snapshot, now: now)
        #expect(paceOnly == "+10%")
    }

    @Test
    func `pace mode without reset date shows nothing`() {
        let snapshot = makeUsageSnapshot(primaryUsedPercent: 60)
        #expect(MenuBarMetricWindowResolver.displayText(mode: .pace, snapshot: snapshot) == nil)
    }
}
