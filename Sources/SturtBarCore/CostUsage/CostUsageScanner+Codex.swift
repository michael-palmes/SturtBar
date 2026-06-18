import Foundation

/// Codex session-log cost scanning. A deliberately small reimplementation of the
/// CodexBar Codex scanner: it reads `~/.codex/sessions` + `archived_sessions`
/// JSONL, sums each `token_count` event's per-turn delta, and prices it with the
/// built-in Codex table. The CodexBar original's fork-baseline inheritance,
/// divergent-totals reconciliation, byte-level fast parser, and SQLite priority
/// map are all intentionally dropped — SturtBar reads no priority metadata and
/// prices every turn at standard rates.
///
/// Per-turn delta: each `token_count` event carries a self-contained
/// `last_token_usage` (the tokens for that turn), so the deltas simply sum.
/// Logs that only emit cumulative `total_token_usage` fall back to total-deltas
/// tracked within the file.
extension CostUsageScanner {
    // MARK: - Roots

    private static func defaultCodexSessionsRoots(options: Options) -> [URL] {
        if let override = options.codexSessionsRoots { return override }

        let home: URL = if let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !env.isEmpty
        {
            URL(fileURLWithPath: env)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }

        return [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    // MARK: - Per-file parse

    /// Parses one Codex session file into a `dayKey -> model -> [input, cached, output]`
    /// aggregate, summing each turn's token delta. Out-of-range days are skipped.
    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        checkCancellation: CancellationCheck? = nil) throws -> [String: [String: [Int]]]
    {
        func toInt(_ value: Any?) -> Int {
            (value as? NSNumber)?.intValue ?? 0
        }

        func totals(_ value: Any?) -> (input: Int, cached: Int, output: Int)? {
            guard let dict = value as? [String: Any] else { return nil }
            return (
                input: max(0, toInt(dict["input_tokens"])),
                cached: max(0, toInt(dict["cached_input_tokens"] ?? dict["cache_read_input_tokens"])),
                output: max(0, toInt(dict["output_tokens"])))
        }

        var days: [String: [String: [Int]]] = [:]
        var currentModel: String?
        var previousTotal: (input: Int, cached: Int, output: Int)?

        func add(dayKey: String, model: String, input: Int, cached: Int, output: Int) {
            guard CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: range.scanSinceKey,
                until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeCodexModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + input
            packed[1] = (packed[safe: 1] ?? 0) + cached
            packed[2] = (packed[safe: 2] ?? 0) + output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        let maxLineBytes = 512 * 1024

        do {
            _ = try CostUsageJsonl.scan(
                fileURL: fileURL,
                maxLineBytes: maxLineBytes,
                prefixBytes: maxLineBytes,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                    // Cheap prefilter: only `turn_context` (model) and `token_count` lines matter.
                    let isTurnContext = line.bytes.containsAscii(#""turn_context""#)
                    let isTokenCount = line.bytes.containsAscii(#""token_count""#)
                    guard isTurnContext || isTokenCount else { return }

                    autoreleasepool {
                        guard
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String
                        else { return }

                        if type == "turn_context" {
                            let payload = (obj["payload"] as? [String: Any]) ?? obj
                            if let model = (payload["model"] as? String) ?? (payload["model_name"] as? String),
                               !model.isEmpty
                            {
                                currentModel = model
                            }
                            return
                        }

                        guard
                            type == "event_msg",
                            let payload = obj["payload"] as? [String: Any],
                            payload["type"] as? String == "token_count",
                            let info = payload["info"] as? [String: Any],
                            let timestamp = obj["timestamp"] as? String,
                            let dayKey = Self.dayKeyFromTimestamp(timestamp) ?? Self.dayKeyFromParsedISO(timestamp)
                        else { return }

                        let recordModel = (info["model"] as? String)
                            ?? (info["model_name"] as? String)
                            ?? (payload["model"] as? String)
                        // turn_context model wins; fall back to the event's own model, then a safe default.
                        let model = currentModel ?? recordModel ?? "gpt-5"

                        let last = totals(info["last_token_usage"])
                        let total = totals(info["total_token_usage"])

                        var deltaInput = 0
                        var deltaCached = 0
                        var deltaOutput = 0
                        if let last {
                            // Self-contained per-turn delta.
                            deltaInput = last.input
                            deltaCached = last.cached
                            deltaOutput = last.output
                            if let total { previousTotal = total }
                        } else if let total {
                            // Derive the delta from cumulative totals.
                            let base = previousTotal ?? (input: 0, cached: 0, output: 0)
                            deltaInput = max(0, total.input - base.input)
                            deltaCached = max(0, total.cached - base.cached)
                            deltaOutput = max(0, total.output - base.output)
                            previousTotal = total
                        } else {
                            return
                        }

                        if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
                        add(
                            dayKey: dayKey,
                            model: model,
                            input: deltaInput,
                            cached: min(deltaCached, deltaInput),
                            output: deltaOutput)
                    }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Best-effort: a read/parse failure yields no rows for this file.
            return [:]
        }

        return days
    }

    // MARK: - Scan

    private final class CodexScanState {
        var cache: CostUsageCache
        var touched: Set<String>
        let range: CostUsageDayRange
        let forceFullScan: Bool
        let checkCancellation: CancellationCheck?

        init(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            forceFullScan: Bool,
            checkCancellation: CancellationCheck?)
        {
            self.cache = cache
            self.touched = []
            self.range = range
            self.forceFullScan = forceFullScan
            self.checkCancellation = checkCancellation
        }
    }

    /// Files modified before the scan window cannot contain in-window turns
    /// (rows are appended as they happen). Skipping them — and letting the
    /// untouched-prune drop their stale cache entries — bounds rebuild cost.
    private static func codexMtimeSkipCutoffMs(range: CostUsageDayRange) -> Int64? {
        guard let scanSinceDate = parseDayKey(range.scanSinceKey) else { return nil }
        let startOfDay = Calendar.current.startOfDay(for: scanSinceDate)
        return Int64(startOfDay.timeIntervalSince1970 * 1000)
    }

    private static func processCodexFile(
        url: URL,
        size: Int64,
        mtimeMs: Int64,
        state: CodexScanState) throws
    {
        try state.checkCancellation?()
        let path = url.path
        state.touched.insert(path)

        if let cached = state.cache.files[path],
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size,
           !state.forceFullScan
        {
            return
        }

        let days = try Self.parseCodexFile(
            fileURL: url,
            range: state.range,
            checkCancellation: state.checkCancellation)
        state.cache.files[path] = Self.makeFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            days: days,
            parsedBytes: nil)
    }

    private static func scanCodexRoot(root: URL, state: CodexScanState) throws {
        try state.checkCancellation?()
        // Missing root: leave its files untouched so the untouched-prune drops them.
        guard FileManager.default.fileExists(atPath: root.path) else { return }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        let mtimeSkipCutoffMs = Self.codexMtimeSkipCutoffMs(range: state.range)

        for case let url as URL in enumerator {
            try state.checkCancellation?()
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let size = Int64(values.fileSize ?? 0)
            if size <= 0 { continue }
            let mtimeMs = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            if let mtimeSkipCutoffMs, mtimeMs < mtimeSkipCutoffMs { continue }
            try Self.processCodexFile(url: url, size: size, mtimeMs: mtimeMs, state: state)
        }
    }

    /// Rebuilds `cache.days` by summing every cached file's per-file day aggregate.
    private static func rebuildCodexDays(cache: inout CostUsageCache) {
        var days: [String: [String: [Int]]] = [:]
        for usage in cache.files.values {
            for (day, models) in usage.days {
                for (model, packed) in models {
                    var dayModels = days[day] ?? [:]
                    var merged = dayModels[model] ?? [0, 0, 0]
                    merged[0] = (merged[safe: 0] ?? 0) + (packed[safe: 0] ?? 0)
                    merged[1] = (merged[safe: 1] ?? 0) + (packed[safe: 1] ?? 0)
                    merged[2] = (merged[safe: 2] ?? 0) + (packed[safe: 2] ?? 0)
                    dayModels[model] = merged
                    days[day] = dayModels
                }
            }
        }
        cache.days = days
    }

    static func loadCodexDaily(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        var cache = CostUsageCacheIO.load(cacheRoot: options.cacheRoot, provider: .codex)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        // Shared models.dev catalog (same pipeline as Claude — no extra network).
        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: options.cacheRoot)

        if shouldRefresh {
            try checkCancellation?()
            if options.forceRescan { cache = CostUsageCache() }

            let state = CodexScanState(
                cache: cache,
                range: range,
                forceFullScan: options.forceRescan || windowExpanded,
                checkCancellation: checkCancellation)

            for root in self.defaultCodexSessionsRoots(options: options) {
                try Self.scanCodexRoot(root: root, state: state)
            }
            try checkCancellation?()

            cache = state.cache
            cache.roots = nil
            for key in cache.files.keys where !state.touched.contains(key) {
                cache.files.removeValue(forKey: key)
            }

            Self.rebuildCodexDays(cache: &cache)
            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            CostUsageCacheIO.save(cache: cache, cacheRoot: options.cacheRoot, provider: .codex)
        }

        return try Self.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: modelsDevCatalog,
            checkCancellation: checkCancellation)
    }

    private static func buildCodexReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog?,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var costSeen = false

        let dayKeys = cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        for day in dayKeys {
            try checkCancellation?()
            guard let models = cache.days[day] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayOutput = 0
            var dayCached = 0
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cached = packed[safe: 1] ?? 0
                let output = packed[safe: 2] ?? 0

                dayInput += input
                dayCached += cached
                dayOutput += output

                // Codex input_tokens already includes the cached subset, so distinct
                // tokens = input + output.
                let modelTokens = input + output
                let cost = CostUsagePricing.codexCostUSD(
                    model: model,
                    inputTokens: input,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    modelsDevCatalog: modelsDevCatalog)
                breakdown.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: modelTokens))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let sortedBreakdown = Self.sortedModelBreakdowns(breakdown)
            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCached,
                cacheCreationTokens: 0,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: sortedBreakdown))

            totalInput += dayInput
            totalOutput += dayOutput
            totalCacheRead += dayCached
            totalTokens += dayTotal
            if let entryCost {
                totalCost += entryCost
                costSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                cacheReadTokens: totalCacheRead,
                cacheCreationTokens: 0,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }
}
