// UsagePace.swift — expected-vs-actual usage pace for a rate window.
//
// Ported as-is from legacy CodexBarCore/UsagePace.swift (Phase 3b). The only change is the
// fileprivate `clamped(to:)` helper, inlined here because SturtBarCore doesn't carry the legacy
// Double+Clamped extension.

import Foundation

public struct UsagePace: Sendable {
    public enum Stage: Sendable {
        case onTrack
        case slightlyAhead
        case ahead
        case farAhead
        case slightlyBehind
        case behind
        case farBehind
    }

    public let stage: Stage
    public let deltaPercent: Double
    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool
    public let runOutProbability: Double?

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double? = nil)
    {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
        self.runOutProbability = runOutProbability
    }

    /// Pace a rate window against an even spread of usage. When `workWeek` is supplied and the
    /// window is the weekly one (10080 minutes), usage is paced over Monday-to-Friday working time
    /// instead of 7 calendar days: the expected marker and the run-out projection both treat
    /// weekends as zero usage, and a mid-week reset is handled by counting only weekday seconds.
    public static func weekly(
        window: RateWindow,
        now: Date = .init(),
        defaultWindowMinutes: Int = 10080,
        workWeek: WorkWeek? = nil) -> UsagePace?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }
        let actual = window.usedPercent.clamped(to: 0...100)

        let expected: Double
        let projection: (etaSeconds: TimeInterval?, willLastToReset: Bool)

        if let workWeek, minutes == 10080 {
            // Measure elapsed and total in weekday-time. The total is computed, never assumed to be
            // five days: under a DST week it can differ by an hour, and using the same weekday walk
            // for both keeps the ratio clean.
            let windowStart = resetsAt.addingTimeInterval(-duration)
            let elapsedWork = workWeek.weekdaySeconds(from: windowStart, to: now)
            let totalWork = workWeek.weekdaySeconds(from: windowStart, to: resetsAt)
            guard totalWork > 0 else { return nil }
            if elapsedWork == 0, actual > 0 { return nil }
            expected = ((elapsedWork / totalWork) * 100).clamped(to: 0...100)
            projection = Self.workWeekProjection(
                actual: actual,
                elapsedWork: elapsedWork,
                workSecondsUntilReset: totalWork - elapsedWork,
                now: now,
                workWeek: workWeek)
        } else {
            let elapsed = (duration - timeUntilReset).clamped(to: 0...duration)
            if elapsed == 0, actual > 0 { return nil }
            expected = ((elapsed / duration) * 100).clamped(to: 0...100)
            projection = Self.calendarProjection(
                actual: actual, elapsed: elapsed, timeUntilReset: timeUntilReset)
        }

        let delta = actual - expected
        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: projection.etaSeconds,
            willLastToReset: projection.willLastToReset,
            runOutProbability: nil)
    }

    /// Flat calendar-time run-out projection (the original behaviour): exhaust the remaining usage
    /// at the rate seen so far and compare against wall-clock time until reset.
    private static func calendarProjection(
        actual: Double,
        elapsed: TimeInterval,
        timeUntilReset: TimeInterval) -> (etaSeconds: TimeInterval?, willLastToReset: Bool)
    {
        if elapsed > 0, actual > 0 {
            let rate = actual / elapsed
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let candidate = remaining / rate
                if candidate >= timeUntilReset { return (nil, true) }
                return (candidate, false)
            }
        } else if elapsed > 0, actual == 0 {
            return (nil, true)
        }
        return (nil, false)
    }

    /// Working-time run-out projection for 5-day pacing. The rate is per working second and the
    /// lasts-to-reset decision is made entirely in working-seconds, so it stays consistent with the
    /// expected marker; only the final ETA is converted back to a wall-clock interval, which skips
    /// the weekend, for display.
    private static func workWeekProjection(
        actual: Double,
        elapsedWork: TimeInterval,
        workSecondsUntilReset: TimeInterval,
        now: Date,
        workWeek: WorkWeek) -> (etaSeconds: TimeInterval?, willLastToReset: Bool)
    {
        if elapsedWork > 0, actual > 0 {
            let rate = actual / elapsedWork
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let candidateWork = remaining / rate
                if candidateWork >= workSecondsUntilReset { return (nil, true) }
                let etaDate = workWeek.date(after: now, consumingWorkingSeconds: candidateWork)
                return (etaDate.timeIntervalSince(now), false)
            }
        } else if elapsedWork > 0, actual == 0 {
            return (nil, true)
        }
        return (nil, false)
    }

    public static func historical(
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double?) -> UsagePace
    {
        let expected = expectedUsedPercent.clamped(to: 0...100)
        let actual = actualUsedPercent.clamped(to: 0...100)
        let delta = actual - expected
        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: runOutProbability)
    }

    private static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }
}

/// A Monday-to-Friday working week, used to pace a weekly window over 5 working days instead of 7
/// calendar days. Carries the calendar (and therefore time zone) so the day-boundary maths is
/// deterministic and testable; production code uses `Calendar.current` (the user's local zone).
public struct WorkWeek: Sendable, Equatable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Seconds of wall-clock time in `[from, to)` that fall on Monday-to-Friday whole calendar
    /// days, measured in this work week's calendar and time zone. Walks local midnights (never a
    /// fixed 86400-second stride) so partial start and end days, and DST-length days, are handled
    /// by construction. Returns 0 for an empty or reversed range.
    func weekdaySeconds(from: Date, to: Date) -> TimeInterval {
        guard from < to else { return 0 }
        var total: TimeInterval = 0
        var dayStart = self.calendar.startOfDay(for: from)
        while dayStart < to {
            guard let nextDayStart = self.calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                break
            }
            if self.isWeekday(dayStart) {
                let segmentStart = max(dayStart, from)
                let segmentEnd = min(nextDayStart, to)
                if segmentEnd > segmentStart {
                    total += segmentEnd.timeIntervalSince(segmentStart)
                }
            }
            dayStart = nextDayStart
        }
        return total
    }

    /// The earliest Date at or after `start` by which `workingSeconds` of Monday-to-Friday time
    /// have elapsed. Weekend days advance the wall clock without consuming the budget, so a Friday
    /// burn rate projects forward across the weekend and lands on the following week.
    func date(after start: Date, consumingWorkingSeconds workingSeconds: TimeInterval) -> Date {
        guard workingSeconds > 0 else { return start }
        var remaining = workingSeconds
        var dayStart = self.calendar.startOfDay(for: start)
        while true {
            guard let nextDayStart = self.calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return start.addingTimeInterval(workingSeconds)
            }
            if self.isWeekday(dayStart) {
                let segmentStart = max(dayStart, start)
                let available = nextDayStart.timeIntervalSince(segmentStart)
                if remaining <= available {
                    return segmentStart.addingTimeInterval(remaining)
                }
                remaining -= available
            }
            dayStart = nextDayStart
        }
    }

    /// True for Monday through Friday. `.weekday` is 1 = Sunday … 7 = Saturday in the Gregorian
    /// calendar, independent of `firstWeekday`, so weekdays are 2...6. Deliberately not
    /// `isDateInWeekend(for:)`, which honours locale-specific weekend days (Friday/Saturday in some
    /// regions) and would violate the fixed Monday-to-Friday contract.
    private func isWeekday(_ date: Date) -> Bool {
        (2...6).contains(self.calendar.component(.weekday, from: date))
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
