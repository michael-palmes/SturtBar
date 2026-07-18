// UpdateCheckPolicy.swift: pure gating for the daily update check (RefreshGatePolicy style).

import Foundation

public enum UpdateCheckPolicy {
    /// Checks run at most daily; 20 h keeps a same-time-each-morning launch pattern eligible.
    public static let minimumInterval: TimeInterval = 20 * 60 * 60
    /// Re-arm cadence while the app stays running.
    public static let rearmInterval: TimeInterval = 24 * 60 * 60

    /// Whether a background check should fire now. The enabled flag is the hard privacy gate.
    public static func shouldCheck(now: Date, lastCheckedAt: Date?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= self.minimumInterval
    }

    /// Seconds until the next background check is due; never sooner than one minute out.
    public static func nextCheckDelay(now: Date, lastCheckedAt: Date?) -> TimeInterval {
        guard let lastCheckedAt else { return 60 }
        return max(60, lastCheckedAt.addingTimeInterval(self.rearmInterval).timeIntervalSince(now))
    }
}
