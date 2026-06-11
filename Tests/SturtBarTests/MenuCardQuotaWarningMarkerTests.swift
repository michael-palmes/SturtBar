// MenuCardQuotaWarningMarkerTests.swift — quota-warning + workday marker coverage (Phase 4a).
//
// Ported from legacy Tests/CodexBarTests/MenuCardQuotaWarningMarkerTests.swift; the Codex
// projection case is re-expressed against the Claude snapshot shape.

import Foundation
import SturtBarCore
import Testing
@testable import SturtBar

struct MenuCardQuotaWarningMarkerTests {
    @Test
    func `quota warning marker geometry is inset and hairline`() {
        let rect = UsageProgressBar.warningMarkerRect(
            x: 50,
            size: CGSize(width: 100, height: 6),
            scale: 2)

        #expect(rect.width == 1)
        #expect(rect.height < 6)
        #expect(rect.minY > 0)
        #expect(abs(rect.midX - 50) <= 0.5)
    }

    @Test
    func `omits quota warning markers for disabled windows`() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            opus: nil,
            updatedAt: now,
            loginMethod: nil)

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            quotaWarningThresholds: [.session: [50], .weekly: []],
            now: now))

        #expect(model.metrics.count == 2)
        #expect(model.metrics.first?.warningMarkerPercents == [50])
        #expect(model.metrics[1].warningMarkerPercents.isEmpty)
    }

    @Test
    func `marker percents flip for used-style bars`() {
        #expect(UsageMenuCardView.Model.warningMarkerPercents(thresholds: [50, 20], showUsed: false) == [50, 20])
        #expect(UsageMenuCardView.Model.warningMarkerPercents(thresholds: [50, 20], showUsed: true) == [50, 80])
        #expect(UsageMenuCardView.Model.warningMarkerPercents(thresholds: nil, showUsed: false).isEmpty)
    }

    @Test
    func `weekly markers merge workday boundaries when configured`() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let input = UsageMenuCardView.Model.Input(
            snapshot: nil,
            quotaWarningThresholds: [.weekly: [25]],
            workDaysPerWeek: 5,
            now: now)

        let markers = UsageMenuCardView.Model.weeklyMarkerPercents(input: input, windowMinutes: 10080)
        #expect(markers == [20.0, 25.0, 40.0, 60.0, 80.0])

        // Non-weekly windows never get workday boundaries.
        let sessionMarkers = UsageMenuCardView.Model.weeklyMarkerPercents(input: input, windowMinutes: 300)
        #expect(sessionMarkers == [25.0])
    }

    @Test
    func `work day marker percents for 5-day week`() {
        #expect(workDayMarkerPercents(workDays: 5, windowMinutes: 10080) == [20.0, 40.0, 60.0, 80.0])
    }

    @Test
    func `work day marker percents for 4-day week`() {
        #expect(workDayMarkerPercents(workDays: 4, windowMinutes: 10080) == [25.0, 50.0, 75.0])
    }

    @Test
    func `work day marker percents for 7-day week`() {
        let markers = workDayMarkerPercents(workDays: 7, windowMinutes: 10080)
        #expect(markers.count == 6)
        #expect(abs(markers[0] - 14.2857) < 0.001)
        #expect(abs(markers[5] - 85.7143) < 0.001)
    }

    @Test
    func `work day marker percents nil work days returns empty`() {
        #expect(workDayMarkerPercents(workDays: nil, windowMinutes: 10080).isEmpty)
    }

    @Test
    func `work day marker percents nil window minutes returns empty`() {
        #expect(workDayMarkerPercents(workDays: 5, windowMinutes: nil).isEmpty)
    }

    @Test
    func `work day marker percents non-weekly window returns empty`() {
        #expect(workDayMarkerPercents(workDays: 5, windowMinutes: 300).isEmpty)
        #expect(workDayMarkerPercents(workDays: 5, windowMinutes: 1440).isEmpty)
    }

    @Test
    func `work day marker percents invalid work days returns empty`() {
        #expect(workDayMarkerPercents(workDays: 1, windowMinutes: 10080).isEmpty)
        #expect(workDayMarkerPercents(workDays: 0, windowMinutes: 10080).isEmpty)
        #expect(workDayMarkerPercents(workDays: 8, windowMinutes: 10080).isEmpty)
        #expect(workDayMarkerPercents(workDays: -1, windowMinutes: 10080).isEmpty)
    }
}
