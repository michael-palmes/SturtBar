// RefreshGatePolicy.swift — the pure min-gap / backoff / rate-limit decision.
//
// Extracted from UsageStore.shouldAttempt so the Claude and Codex lanes share ONE copy of the
// policy math (duplicating it was the documented drift risk). Pure function of its inputs; the
// store wrappers own logging and field plumbing. Behavior is identical to the pre-extraction
// code — the refresh-policy test suite pins it.

import Foundation

enum RefreshGateDecision: Equatable {
    case proceed
    /// Rate-limit gate: blocks ALL triggers (manual included) until the server-provided date.
    case rateLimited(until: Date)
    /// Min-gap suppression (menuOpen 30s; interval/wake half-interval since last success).
    case tooSoon
    /// Failure backoff: automatic triggers wait min(interval × 2^streak, 30 min) since the
    /// last attempt.
    case backingOff
}

enum RefreshGatePolicy {
    static let menuOpenMinimumGapSeconds: TimeInterval = 30
    static let backoffCapSeconds: TimeInterval = 30 * 60

    /// One lane's gate-relevant fields, snapshotted at decision time.
    struct LaneState {
        let health: FetchHealth
        let lastSuccessAt: Date?
        let lastAttemptAt: Date?
        let failureStreak: Int
    }

    static func decision(
        trigger: RefreshTrigger,
        lane: LaneState,
        intervalSeconds: TimeInterval,
        now: Date) -> RefreshGateDecision
    {
        if case let .rateLimited(until) = lane.health, now < until {
            return .rateLimited(until: until)
        }

        switch trigger {
        case .manual, .launch:
            return .proceed

        case .menuOpen:
            guard let lastSuccessAt = lane.lastSuccessAt else { return .proceed }
            return now.timeIntervalSince(lastSuccessAt) >= self.menuOpenMinimumGapSeconds
                ? .proceed
                : .tooSoon

        case .interval, .wake:
            if let lastSuccessAt = lane.lastSuccessAt,
               now.timeIntervalSince(lastSuccessAt) < intervalSeconds / 2
            {
                return .tooSoon
            }
            if lane.failureStreak > 0, let lastAttemptAt = lane.lastAttemptAt {
                let backoff = min(
                    intervalSeconds * pow(2, Double(lane.failureStreak)),
                    self.backoffCapSeconds)
                if now.timeIntervalSince(lastAttemptAt) < backoff {
                    return .backingOff
                }
            }
            return .proceed
        }
    }
}
