import Foundation

/// Ported from CodexBar's vendored CostUsageScanner, trimmed to the Claude
/// JSONL scan. The legacy file also carried the codex session parser (fork/turn
/// dedup, trace-DB priority pricing, codex roots resolution); all of that was
/// dropped with the Codex trim.
enum CostUsageScanner {
    typealias CancellationCheck = () throws -> Void

    static let log = SturtBarLog.logger("cost-usage")

    /// Performance bound (rebuild): the Claude scan window never exceeds this
    /// many days (inclusive). Requests for longer histories are clamped to the
    /// most recent `claudeScanWindowMaxDays` days ending at `until`.
    static let claudeScanWindowMaxDays = 30

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false

        init(
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            forceRescan: Bool = false)
        {
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.forceRescan = forceRescan
        }
    }

    struct ClaudeParseResult {
        let rows: [ClaudeUsageRow]
        let parsedBytes: Int64
    }

    enum ClaudePathRole: String, Codable {
        case parent
        case subagent
    }

    struct ClaudeUsageRow: Codable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let messageId: String?
        let requestId: String?
        let timestampUnixMs: Int64?
        let isSidechain: Bool
        let pathRole: ClaudePathRole
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int?
        let output: Int
        let costNanos: Int
        let costPriced: Bool?
    }

    /// Convenience wrapper that silently swallows any thrown error — including
    /// `CancellationError` — returning an empty report on failure.
    ///
    /// - Important: Production call sites that need to propagate cancellation
    ///   must call `loadDailyReportCancellable` instead; this function will
    ///   swallow a `CancellationError` into an empty report without rethrowing.
    static func loadDailyReport(
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        (
            try? self.loadDailyReportCancellable(
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: nil)) ?? CostUsageDailyReport(data: [], summary: nil)
    }

    static func loadDailyReportCancellable(
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        // Performance bound (rebuild): clamp the requested day range to the
        // most recent `claudeScanWindowMaxDays` days. The window is inclusive,
        // so a 30-day cap starts 29 days before `until`.
        let windowFloor = Calendar.current.date(
            byAdding: .day,
            value: -(self.claudeScanWindowMaxDays - 1),
            to: until) ?? since
        let clampedSince = max(since, windowFloor)
        let range = CostUsageDayRange(since: clampedSince, until: until)
        try checkCancellation?()

        return try self.loadClaudeDaily(
            range: range,
            now: now,
            options: options,
            checkCancellation: checkCancellation)
    }

    // MARK: - Day keys

    struct CostUsageDayRange {
        let sinceKey: String
        let untilKey: String
        let scanSinceKey: String
        let scanUntilKey: String

        init(since: Date, until: Date) {
            self.sinceKey = Self.dayKey(from: since)
            self.untilKey = Self.dayKey(from: until)
            self.scanSinceKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: -1, to: since) ?? since)
            self.scanUntilKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until)
        }

        static func dayKey(from date: Date) -> String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let y = comps.year ?? 1970
            let m = comps.month ?? 1
            let d = comps.day ?? 1
            return String(format: "%04d-%02d-%02d", y, m, d)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            if dayKey < since { return false }
            if dayKey > until { return false }
            return true
        }
    }
}
