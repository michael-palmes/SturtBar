// UsageStore+ResetBoundaryRefresh.swift: one-shot refresh just past a quota reset boundary.

import Foundation
import SturtBarCore

/// Grace waits for the server to roll the window over; minimum delay avoids a tight-loop refire.
struct ResetBoundaryTiming {
    var graceSeconds: TimeInterval = 60
    var minimumDelaySeconds: TimeInterval = 5
}

extension UsageStore {
    struct ResetBoundaryCandidate: Equatable {
        /// When the task should fire (boundary, but never sooner than now + minimum delay).
        let refreshAt: Date
        /// The boundary instant used for the attempted-once dedup.
        let boundary: Date
    }

    private static let boundaryLog = SturtBarLog.logger("reset-boundary")

    func scheduleResetBoundaryRefreshIfNeeded() {
        let now = self.now()
        let snapshots = [
            self.settings.claudeProviderEnabled ? self.usage : nil,
            self.settings.codexProviderEnabled ? self.codexUsage : nil,
        ]
        guard let candidate = Self.nextResetBoundaryCandidate(
            snapshots: snapshots,
            intervalSeconds: self.settings.refreshFrequency.seconds,
            attempted: self.attemptedResetBoundaryRefreshes,
            timing: self.resetBoundaryTiming,
            now: now)
        else {
            self.cancelResetBoundaryRefresh()
            return
        }

        // Same instant already scheduled: keep the existing task.
        if let scheduled = self.scheduledResetBoundaryAt,
           self.resetBoundaryTask != nil,
           abs(scheduled.timeIntervalSince(candidate.refreshAt)) < 1
        {
            return
        }

        self.cancelResetBoundaryRefresh()
        self.scheduledResetBoundaryAt = candidate.refreshAt
        let delay = max(0, candidate.refreshAt.timeIntervalSince(now))
        let boundary = candidate.boundary
        Self.boundaryLog.debug(
            "Reset boundary refresh scheduled",
            metadata: ["inSeconds": String(format: "%.0f", delay)])
        self.resetBoundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.resetBoundaryTask = nil
            self.scheduledResetBoundaryAt = nil
            self.recordAttemptedResetBoundary(boundary)
            guard !self.isRefreshing else { return }
            Self.boundaryLog.info("Reset boundary refresh firing")
            await self.refresh(trigger: .resetBoundary)
        }
    }

    func cancelResetBoundaryRefresh() {
        self.resetBoundaryTask?.cancel()
        self.resetBoundaryTask = nil
        self.scheduledResetBoundaryAt = nil
    }

    private func recordAttemptedResetBoundary(_ boundary: Date) {
        self.attemptedResetBoundaryRefreshes.insert(boundary)
        if self.attemptedResetBoundaryRefreshes.count > 64,
           let oldest = self.attemptedResetBoundaryRefreshes.min()
        {
            self.attemptedResetBoundaryRefreshes.remove(oldest)
        }
    }

    /// Pure candidate selection: the earliest actionable boundary across the enabled lanes.
    static func nextResetBoundaryCandidate(
        snapshots: [ProviderUsageSnapshot?],
        intervalSeconds: TimeInterval?,
        attempted: Set<Date>,
        timing: ResetBoundaryTiming,
        now: Date) -> ResetBoundaryCandidate?
    {
        // With an interval cadence, boundaries past the next tick are the tick's job.
        let horizon = intervalSeconds.map { now.addingTimeInterval($0) }
        return snapshots
            .compactMap(\.self)
            .flatMap { snapshot in
                snapshot.resetBoundaryDates.compactMap { resetsAt -> ResetBoundaryCandidate? in
                    let boundary = resetsAt.addingTimeInterval(timing.graceSeconds)
                    guard !attempted.contains(boundary) else { return nil }
                    if let horizon, boundary > horizon { return nil }
                    // Data already refreshed past the boundary has nothing to gain.
                    guard snapshot.updatedAt < boundary else { return nil }
                    return ResetBoundaryCandidate(
                        refreshAt: max(boundary, now.addingTimeInterval(timing.minimumDelaySeconds)),
                        boundary: boundary)
                }
            }
            .min { $0.refreshAt < $1.refreshAt }
    }
}

extension ProviderUsageSnapshot {
    fileprivate var resetBoundaryDates: [Date] {
        let windows = [self.primary, self.secondary, self.opus].compactMap(\.self)
            + self.extraRateWindows.map(\.window)
            + self.modelWeeklyWindows.map(\.window)
        return windows.compactMap(\.resetsAt)
    }
}
