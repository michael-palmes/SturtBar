// UsagePaceWorkWeekTests.swift — 5-day work-week (Mon-Fri) pacing.
//
// Covers the WorkWeek weekday-time helpers and the work-week branch of UsagePace.weekly.
// All dates and calendars are built with an explicit time zone so the suite never depends on
// the machine's local zone or DST rules.

import Foundation
import Testing
@testable import SturtBarCore

struct UsagePaceWorkWeekTests {
    // MARK: Fixtures

    private static let gmt = TimeZone(identifier: "GMT")!
    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let adelaide = TimeZone(identifier: "Australia/Adelaide")!

    private func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    private func workWeek(_ tz: TimeZone) -> WorkWeek {
        WorkWeek(calendar: self.calendar(tz))
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        tz: TimeZone) -> Date
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: weekdaySeconds

    @Test
    func `weekday seconds counts five whole days for a clean week`() {
        // Mon 2024-01-01 00:00 -> Mon 2024-01-08 00:00 (one of each weekday).
        let ww = self.workWeek(Self.gmt)
        let from = self.date(2024, 1, 1, tz: Self.gmt)
        let to = self.date(2024, 1, 8, tz: Self.gmt)
        #expect(ww.weekdaySeconds(from: from, to: to) == 5 * 24 * 3600)
    }

    @Test
    func `weekday seconds clips partial start and end days to one whole day`() {
        // Mon 12:00 -> next Mon 12:00: the two partial Mondays sum to one weekday-day.
        let ww = self.workWeek(Self.gmt)
        let from = self.date(2024, 1, 1, 12, tz: Self.gmt)
        let to = self.date(2024, 1, 8, 12, tz: Self.gmt)
        #expect(ww.weekdaySeconds(from: from, to: to) == 5 * 24 * 3600)
    }

    @Test
    func `weekday seconds excludes the weekend span`() {
        // Fri 12:00 -> Mon 12:00: Fri PM (12h) + Mon AM (12h), Sat and Sun excluded.
        let ww = self.workWeek(Self.gmt)
        let from = self.date(2024, 1, 5, 12, tz: Self.gmt)
        let to = self.date(2024, 1, 8, 12, tz: Self.gmt)
        #expect(ww.weekdaySeconds(from: from, to: to) == 24 * 3600)
    }

    @Test
    func `weekday seconds returns zero for a reversed or empty range`() {
        let ww = self.workWeek(Self.gmt)
        let a = self.date(2024, 1, 3, tz: Self.gmt)
        let b = self.date(2024, 1, 5, tz: Self.gmt)
        #expect(ww.weekdaySeconds(from: b, to: a) == 0)
        #expect(ww.weekdaySeconds(from: a, to: a) == 0)
    }

    @Test
    func `weekday seconds walks local midnights across spring forward`() {
        // America/New_York spring forward is Sun 2024-03-10 (23h local day).
        // Sat 00:00 -> Tue 00:00 spans Sat+Sun (weekend) plus a full Monday.
        // Correct local-midnight walking yields exactly one weekday-day (86400);
        // a naive +86400 walk would drift by the lost hour and return 82800.
        let ww = self.workWeek(Self.newYork)
        let from = self.date(2024, 3, 9, tz: Self.newYork)
        let to = self.date(2024, 3, 12, tz: Self.newYork)
        #expect(ww.weekdaySeconds(from: from, to: to) == 24 * 3600)
    }

    // MARK: date(after:consumingWorkingSeconds:)

    @Test
    func `date after consuming working seconds skips the weekend`() {
        // From Fri 23:00 consume 2h: 1h on Fri, skip Sat and Sun, 1h into Monday -> Mon 01:00.
        let ww = self.workWeek(Self.gmt)
        let start = self.date(2024, 1, 5, 23, tz: Self.gmt)
        let result = ww.date(after: start, consumingWorkingSeconds: 2 * 3600)
        #expect(result == self.date(2024, 1, 8, 1, tz: Self.gmt))
    }

    @Test
    func `date after consuming zero returns the start`() {
        let ww = self.workWeek(Self.gmt)
        let start = self.date(2024, 1, 5, 23, tz: Self.gmt)
        #expect(ww.date(after: start, consumingWorkingSeconds: 0) == start)
        #expect(ww.date(after: start, consumingWorkingSeconds: -10) == start)
    }

    @Test
    func `date after consuming within a single weekday lands the same day`() {
        let ww = self.workWeek(Self.gmt)
        let start = self.date(2024, 1, 2, 9, tz: Self.gmt) // Tuesday 09:00
        let result = ww.date(after: start, consumingWorkingSeconds: 3 * 3600)
        #expect(result == self.date(2024, 1, 2, 12, tz: Self.gmt))
    }

    // MARK: weekly(... workWeek:)

    /// Mid-week reset window: starts Wed 2024-01-03 12:00, resets Wed 2024-01-10 12:00 (GMT).
    private func midWeekWindow(usedPercent: Double) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 10080,
            resetsAt: self.date(2024, 1, 10, 12, tz: Self.gmt),
            resetDescription: nil)
    }

    private var midWeekNow: Date {
        self.date(2024, 1, 5, 18, tz: Self.gmt)
    } // Friday 18:00

    @Test
    func `work week pace expected uses weekday seconds only`() {
        // Window start Mon 2024-01-01 00:00, reset Mon 2024-01-08 00:00, now Wed 00:00.
        // Two of five weekdays elapsed -> 40% (vs 28.57% under flat 7-day pacing).
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: self.date(2024, 1, 8, tz: Self.gmt),
            resetDescription: nil)
        let pace = UsagePace.weekly(
            window: window, now: self.date(2024, 1, 3, tz: Self.gmt), workWeek: self.workWeek(Self.gmt))

        #expect(pace != nil)
        guard let pace else { return }
        #expect(abs(pace.expectedUsedPercent - 40.0) < 0.01)
        #expect(abs(pace.deltaPercent) < 0.01)
        #expect(pace.stage == .onTrack)
    }

    @Test
    func `work week pace freezes over the weekend`() {
        let window = RateWindow(
            usedPercent: 90,
            windowMinutes: 10080,
            resetsAt: self.date(2024, 1, 8, tz: Self.gmt),
            resetDescription: nil)
        let paceSat = UsagePace.weekly(
            window: window, now: self.date(2024, 1, 6, 12, tz: Self.gmt), workWeek: self.workWeek(Self.gmt))
        let paceSun = UsagePace.weekly(
            window: window, now: self.date(2024, 1, 7, 12, tz: Self.gmt), workWeek: self.workWeek(Self.gmt))

        #expect(paceSat != nil)
        #expect(paceSun != nil)
        guard let paceSat, let paceSun else { return }
        #expect(abs(paceSat.expectedUsedPercent - 100.0) < 0.01)
        #expect(paceSat.expectedUsedPercent == paceSun.expectedUsedPercent)
    }

    @Test
    func `work week pace eta skips the weekend and lands next week`() {
        let pace = UsagePace.weekly(
            window: self.midWeekWindow(usedPercent: 80), now: self.midWeekNow, workWeek: self.workWeek(Self.gmt))

        #expect(pace != nil)
        guard let pace else { return }
        #expect(pace.willLastToReset == false)
        #expect(pace.etaSeconds != nil)
        // 13.5 working hours from Fri 18:00 crosses Sat/Sun and lands Mon 07:30.
        #expect(abs((pace.etaSeconds ?? 0) - 221_400) < 1)
        // Wall-clock ETA dwarfs the ~48600s of pure working time, proving the weekend was skipped.
        #expect((pace.etaSeconds ?? 0) > 2 * 24 * 3600)
    }

    @Test
    func `work week pace decides lasts to reset in working seconds`() {
        // Guards the subtle bug: lasts-to-reset must be decided in working-seconds, not wall-clock.
        // candidateWork (291600) >= working time to reset (237600) -> lasts; but candidateWork is
        // less than the wall-clock time to reset (410400), so a wall-clock test would wrongly
        // produce an ETA.
        let pace = UsagePace.weekly(
            window: self.midWeekWindow(usedPercent: 40), now: self.midWeekNow, workWeek: self.workWeek(Self.gmt))

        #expect(pace != nil)
        guard let pace else { return }
        #expect(abs(pace.expectedUsedPercent - 45.0) < 0.01)
        #expect(pace.willLastToReset == true)
        #expect(pace.etaSeconds == nil)
    }

    @Test
    func `work week pace returns nil when no weekday has elapsed`() {
        // Window start Sat 2024-01-06 00:00, now Sun 12:00 (still the opening weekend), usage present.
        let window = RateWindow(
            usedPercent: 5,
            windowMinutes: 10080,
            resetsAt: self.date(2024, 1, 13, tz: Self.gmt),
            resetDescription: nil)
        #expect(UsagePace.weekly(
            window: window, now: self.date(2024, 1, 7, 12, tz: Self.gmt), workWeek: self.workWeek(Self.gmt)) == nil)
    }

    @Test
    func `work week pacing is ignored for a non-weekly window`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)
        let withWW = UsagePace.weekly(
            window: window, now: now, defaultWindowMinutes: 300, workWeek: self.workWeek(Self.gmt))
        let without = UsagePace.weekly(
            window: window, now: now, defaultWindowMinutes: 300, workWeek: nil)

        #expect(withWW != nil)
        #expect(without != nil)
        guard let withWW, let without else { return }
        #expect(withWW.expectedUsedPercent == without.expectedUsedPercent)
        #expect(withWW.deltaPercent == without.deltaPercent)
        #expect(withWW.willLastToReset == without.willLastToReset)
        #expect(withWW.etaSeconds == without.etaSeconds)
    }

    @Test
    func `work week pace is nil when reset missing`() {
        let window = RateWindow(
            usedPercent: 10, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        #expect(UsagePace.weekly(
            window: window, now: self.date(2024, 1, 3, tz: Self.gmt), workWeek: self.workWeek(Self.gmt)) == nil)
    }

    @Test
    func `work week pace stays finite across spring forward`() {
        // America/New_York spring forward is Sun 2024-03-10; the window straddles it.
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: self.date(2024, 3, 15, tz: Self.newYork),
            resetDescription: nil)
        let pace = UsagePace.weekly(
            window: window, now: self.date(2024, 3, 13, tz: Self.newYork), workWeek: self.workWeek(Self.newYork))

        #expect(pace != nil)
        guard let pace else { return }
        #expect(!pace.expectedUsedPercent.isNaN)
        #expect(pace.expectedUsedPercent >= 0 && pace.expectedUsedPercent <= 100)
        #expect(pace.expectedUsedPercent > 0)
    }

    @Test
    func `work week pace stays finite across fall back`() {
        // America/New_York fall back is Sun 2024-11-03; the window straddles it.
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: self.date(2024, 11, 8, tz: Self.newYork),
            resetDescription: nil)
        let pace = UsagePace.weekly(
            window: window, now: self.date(2024, 11, 6, tz: Self.newYork), workWeek: self.workWeek(Self.newYork))

        #expect(pace != nil)
        guard let pace else { return }
        #expect(!pace.expectedUsedPercent.isNaN)
        #expect(pace.expectedUsedPercent >= 0 && pace.expectedUsedPercent <= 100)
    }

    @Test
    func `work week pace respects a half-hour time zone boundary`() {
        // Australia/Adelaide is UTC+10:30 in January. Window start Mon 00:00, now Mon 00:30 local.
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: self.date(2024, 1, 8, tz: Self.adelaide),
            resetDescription: nil)
        let pace = UsagePace.weekly(
            window: window,
            now: self.date(2024, 1, 1, 0, 30, tz: Self.adelaide),
            workWeek: self.workWeek(Self.adelaide))

        #expect(pace != nil)
        guard let pace else { return }
        // 30 minutes of the first Monday out of five weekday-days.
        #expect(abs(pace.expectedUsedPercent - (1800.0 / 432_000.0 * 100.0)) < 0.001)
    }
}
