// UsageFormatterTests.swift — ported from legacy CodexBarTests/UsageFormatterTests.swift,
// Claude-relevant cases only (Phase 3b).
//
// Dropped with rationale:
//   - localization-provider/locale-provider injection tests + zh-Hans/zh-Hant cases + the
//     .strings-table placeholder audit: the rebuild formatter has no localization layer
//     (English literals, fixed en_US/en_US_POSIX locales).
//   - creditsString / kiroCreditNumber / creditShort / creditEvent*: Codex/Kiro credits.
//   - cleanPlanName ("oauth" → "Ollama"): ClaudePlan owns plan naming in the rebuild.
//   - modelCostDetail "Research Preview" label: Codex pricing-label lookup was trimmed.

import Foundation
import Testing
@testable import SturtBarCore

struct UsageFormatterTests {
    // MARK: - Usage line

    @Test
    func `formats usage line`() {
        let line = UsageFormatter.usageLine(remaining: 25, used: 75, showUsed: false)
        #expect(line == "25% left")
    }

    @Test
    func `formats usage line show used`() {
        let line = UsageFormatter.usageLine(remaining: 25, used: 75, showUsed: true)
        #expect(line == "75% used")
    }

    @Test
    func `usage line clamps out of range percentages`() {
        #expect(UsageFormatter.usageLine(remaining: -5, used: 105, showUsed: false) == "0% left")
        #expect(UsageFormatter.usageLine(remaining: -5, used: 105, showUsed: true) == "100% used")
    }

    // MARK: - Updated-ago

    @Test
    func `updated just now`() {
        let now = Date(timeIntervalSince1970: 1_710_048_000)
        #expect(UsageFormatter.updatedString(from: now.addingTimeInterval(-30), now: now) == "Updated just now")
    }

    @Test
    func `relative updated recent`() {
        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let text = UsageFormatter.updatedString(from: fiveHoursAgo, now: now)
        #expect(text.hasPrefix("Updated "))
        #expect(text.contains("5"))
        #expect(text.lowercased().contains("ago"))
    }

    @Test
    func `absolute updated old`() {
        let now = Date()
        let dayAgo = now.addingTimeInterval(-26 * 3600)
        let text = UsageFormatter.updatedString(from: dayAgo, now: now)
        #expect(text.contains("Updated"))
        #expect(!text.contains("ago"))
    }

    // MARK: - Reset countdown

    @Test
    func `reset countdown minutes`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(10 * 60 + 1)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 11m")
    }

    @Test
    func `reset countdown hours and minutes`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3 * 3600 + 31 * 60)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 3h 31m")
    }

    @Test
    func `reset countdown days and hours`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval((26 * 3600) + 10)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 1d 2h")
    }

    @Test
    func `reset countdown exact hour`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 1h")
    }

    @Test
    func `reset countdown past date`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(-10)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "now")
    }

    @Test
    func `reset line uses countdown when resets at is available`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(10 * 60 + 1)
        let window = RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: reset, resetDescription: "Resets soon")
        let text = UsageFormatter.resetLine(for: window, style: .countdown, now: now)
        #expect(text == "Resets in 11m")
    }

    @Test
    func `reset line absolute style renders a clock time, not a countdown`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(90 * 60) // same calendar moment + 1.5h
        let window = RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: reset, resetDescription: "Resets soon")
        let absolute = UsageFormatter.resetLine(for: window, style: .absolute, now: now)
        #expect(absolute?.hasPrefix("Resets ") == true)
        #expect(absolute?.contains(":") == true) // a clock time
        #expect(absolute?.contains("in ") == false)
        #expect(absolute != UsageFormatter.resetLine(for: window, style: .countdown, now: now))
    }

    @Test
    func `reset line falls back to provided description`() {
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "Resets at 23:30 (UTC)")
        let countdown = UsageFormatter.resetLine(for: window, style: .countdown)
        let absolute = UsageFormatter.resetLine(for: window, style: .absolute)
        #expect(countdown == "Resets at 23:30 (UTC)")
        #expect(absolute == "Resets at 23:30 (UTC)")
    }

    @Test
    func `reset line is nil without reset data`() {
        let window = RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "  ")
        #expect(UsageFormatter.resetLine(for: window, style: .countdown) == nil)
    }

    // MARK: - Model labels

    @Test
    func `model display name strips trailing dates`() {
        #expect(UsageFormatter.modelDisplayName("claude-opus-4-5-20251101") == "claude-opus-4-5")
        #expect(UsageFormatter.modelDisplayName("gpt-4o-2024-08-06") == "gpt-4o")
        #expect(UsageFormatter.modelDisplayName("Claude Opus 4.5 2025 1101") == "Claude Opus 4.5")
        #expect(UsageFormatter.modelDisplayName("claude-sonnet-4-5") == "claude-sonnet-4-5")
    }

    @Test
    func `model cost detail joins cost and token counts`() {
        #expect(UsageFormatter.modelCostDetail("claude-fable-5", costUSD: 0.42, totalTokens: 1200) == "$0.42 · 1.2K")
        #expect(UsageFormatter.modelCostDetail("claude-fable-5", costUSD: 0.42, totalTokens: nil) == "$0.42")
        #expect(UsageFormatter.modelCostDetail("claude-fable-5", costUSD: nil, totalTokens: 987) == "987")
        #expect(UsageFormatter.modelCostDetail("claude-fable-5", costUSD: nil, totalTokens: nil) == nil)
    }

    // MARK: - Currency formatting

    @Test
    func `currency string formats USD correctly`() {
        let result = UsageFormatter.currencyString(54.72, currencyCode: "USD")
        #expect(result == "$54.72")
        #expect(!result.contains("$ ")) // No space after symbol
    }

    @Test
    func `currency string handles large values`() {
        let result = UsageFormatter.currencyString(1234.56, currencyCode: "USD")
        #expect(result == "$1,234.56")
    }

    @Test
    func `currency string handles very large values`() {
        let result = UsageFormatter.currencyString(1_234_567.89, currencyCode: "USD")
        #expect(result == "$1,234,567.89")
    }

    @Test
    func `currency string handles negative values`() {
        // Negative sign should come before the dollar sign: -$54.72 (not $-54.72)
        #expect(UsageFormatter.currencyString(-54.72, currencyCode: "USD") == "-$54.72")
        #expect(UsageFormatter.currencyString(-1234.56, currencyCode: "USD") == "-$1,234.56")
    }

    @Test
    func `usd string matches currency string`() {
        #expect(UsageFormatter.usdString(54.72) == UsageFormatter.currencyString(54.72, currencyCode: "USD"))
        #expect(UsageFormatter.usdString(-1234.56) == UsageFormatter.currencyString(-1234.56, currencyCode: "USD"))
        #expect(UsageFormatter.usdString(0) == UsageFormatter.currencyString(0, currencyCode: "USD"))
    }

    @Test
    func `currency string handles zero`() {
        #expect(UsageFormatter.currencyString(0, currencyCode: "USD") == "$0.00")
    }

    @Test
    func `currency string handles non USD currencies`() {
        #expect(UsageFormatter.currencyString(54.72, currencyCode: "EUR") == "€54.72")
        #expect(UsageFormatter.currencyString(54.72, currencyCode: "GBP") == "£54.72")
        #expect(UsageFormatter.currencyString(-1234.56, currencyCode: "EUR") == "-€1,234.56")
    }

    @Test
    func `currency string handles small values`() {
        #expect(UsageFormatter.currencyString(0.001, currencyCode: "USD") == "$0.00")
        let halfCent = UsageFormatter.currencyString(0.005, currencyCode: "USD")
        #expect(halfCent == "$0.00" || halfCent == "$0.01") // Rounding behavior may vary
        #expect(UsageFormatter.currencyString(0.01, currencyCode: "USD") == "$0.01")
    }

    @Test
    func `currency string handles boundary values`() {
        #expect(UsageFormatter.currencyString(999.99, currencyCode: "USD") == "$999.99")
        #expect(UsageFormatter.currencyString(1000.00, currencyCode: "USD") == "$1,000.00")
        #expect(UsageFormatter.currencyString(1000.01, currencyCode: "USD") == "$1,000.01")
    }

    // MARK: - Counts

    @Test
    func `token count string scales units`() {
        #expect(UsageFormatter.tokenCountString(987) == "987")
        #expect(UsageFormatter.tokenCountString(1200) == "1.2K")
        #expect(UsageFormatter.tokenCountString(15000) == "15K")
        #expect(UsageFormatter.tokenCountString(2_500_000) == "2.5M")
        #expect(UsageFormatter.tokenCountString(3_000_000_000) == "3B")
        #expect(UsageFormatter.tokenCountString(-1200) == "-1.2K")
    }

    @Test
    func `byte count string formats binary units`() {
        #expect(UsageFormatter.byteCountString(0) == "0 B")
        #expect(UsageFormatter.byteCountString(512) == "512 B")
        #expect(UsageFormatter.byteCountString(1536) == "1.5 KB")
        #expect(UsageFormatter.byteCountString(10 * 1024) == "10 KB")
        #expect(UsageFormatter.byteCountString(5 * 1024 * 1024) == "5 MB")
        #expect(UsageFormatter.byteCountString(Int64(1536 * 1024 * 1024)) == "1.5 GB")
    }

    // MARK: - Text utilities

    @Test
    func `truncated single line collapses newlines and caps length`() {
        #expect(UsageFormatter.truncatedSingleLine("a\nb") == "a b")
        let long = String(repeating: "x", count: 100)
        let truncated = UsageFormatter.truncatedSingleLine(long, max: 10)
        #expect(truncated == "xxxxxxxxxx…")
    }
}
