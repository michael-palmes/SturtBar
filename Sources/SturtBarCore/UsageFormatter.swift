// UsageFormatter.swift — usage-value formatting helpers for menu/icon text.
//
// Ported from legacy CodexBarCore/UsageFormatter.swift (Phase 3b), absorbing the minimal
// `currencyString` stub that previously lived in UsageModels.swift.
//
// Rebuild changes vs legacy:
//   - Localization-provider/locale-provider indirection dropped — plain English literals with
//     fixed en_US/en_US_POSIX locales (the rebuild has no localization layer; fixed locales keep
//     output deterministic regardless of system locale).
//   - Provider-specific helpers dropped: creditsString/kiroCreditNumber/creditShort/creditEvent*
//     (Codex/Kiro credits), cleanPlanName (ClaudePlan owns plan naming), the Codex
//     "Research Preview" label lookup inside modelCostDetail.
//   - costEstimateHint keeps only the Claude wording.

import Foundation

public enum ResetTimeDisplayStyle: String, Codable, Sendable {
    case countdown
    case absolute
}

public enum UsageFormatter {
    /// Stable formatting locale (legacy default when no provider was injected).
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    // MARK: - Percent lines

    public static func usageLine(remaining: Double, used: Double, showUsed: Bool) -> String {
        let percent = showUsed ? used : remaining
        let suffix = showUsed ? "used" : "left"
        return "\(self.percentText(percent)) \(suffix)"
    }

    /// Clamps to 0...100; every positive value below one percent renders as "<1%" rather than rounding.
    public static func percentText(_ percent: Double) -> String {
        let clamped = min(100, max(0, percent))
        if clamped > 0, clamped < 1 { return "<1%" }
        return String(format: "%.0f%%", clamped)
    }

    // MARK: - Reset descriptions

    public static func resetCountdownDescription(from date: Date, now: Date = .init()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 1 { return "now" }

        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return "in \(days)d \(hours)h" }
            return "in \(days)d"
        }
        if hours > 0 {
            if minutes > 0 { return "in \(hours)h \(minutes)m" }
            return "in \(hours)h"
        }
        return "in \(totalMinutes)m"
    }

    public static func resetDescription(from date: Date, now: Date = .init()) -> String {
        // Human-friendly phrasing: today / tomorrow / date+time.
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(self.posixLocale))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "tomorrow, \(date.formatted(.dateTime.hour().minute().locale(self.posixLocale)))"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(self.posixLocale))
    }

    public static func resetLine(
        for window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date = .init()) -> String?
    {
        if let date = window.resetsAt {
            if style == .countdown {
                let countdown = self.resetCountdownDescription(from: date, now: now)
                if countdown == "now" {
                    return "Resets now"
                }
                if countdown.hasPrefix("in ") {
                    return "Resets in \(countdown.dropFirst(3))"
                }
                return "Resets \(countdown)"
            }
            return "Resets \(self.resetDescription(from: date, now: now))"
        }

        if let desc = window.resetDescription {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.lowercased().hasPrefix("resets in ") {
                return "Resets in \(trimmed.dropFirst("Resets in ".count))"
            }
            if trimmed.lowercased().hasPrefix("resets ") {
                return "Resets \(trimmed.dropFirst("Resets ".count))"
            }
            return "Resets \(trimmed)"
        }
        return nil
    }

    // MARK: - Updated-ago

    public static func updatedString(from date: Date, now: Date = .init()) -> String {
        let delta = now.timeIntervalSince(date)
        if abs(delta) < 60 {
            return "Updated just now"
        }
        if let hours = Calendar.current.dateComponents([.hour], from: date, to: now).hour, hours < 24 {
            let rel = RelativeDateTimeFormatter()
            rel.locale = self.posixLocale
            rel.unitsStyle = .abbreviated
            return "Updated \(rel.localizedString(for: date, relativeTo: now))"
        }
        return "Updated \(date.formatted(.dateTime.hour().minute().locale(self.posixLocale)))"
    }

    // MARK: - Currency

    /// Formats a currency value with the specified currency code.
    /// Uses FormatStyle with explicit en_US locale to ensure consistent formatting
    /// regardless of the user's system locale (e.g., pt-BR users see $54.72 not US$ 54,72).
    public static func currencyString(_ value: Double, currencyCode: String) -> String {
        value.formatted(.currency(code: currencyCode).locale(Locale(identifier: "en_US")))
    }

    /// Formats a USD value with proper negative handling and thousand separators.
    public static func usdString(_ value: Double) -> String {
        self.currencyString(value, currencyCode: "USD")
    }

    public static let costEstimateHint =
        "Estimated from local logs at API rates; token totals include cached tokens and may differ " +
        "from each tool's reported usage."

    // MARK: - Counts

    public static func tokenCountString(_ value: Int) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""

        let units: [(threshold: Int, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1000, 1000, "K"),
        ]

        for unit in units where absValue >= unit.threshold {
            let scaled = Double(absValue) / unit.divisor
            let formatted: String
            if scaled >= 10 {
                formatted = String(format: "%.0f", scaled)
            } else {
                var s = String(format: "%.1f", scaled)
                if s.hasSuffix(".0") { s.removeLast(2) }
                formatted = s
            }
            return "\(sign)\(formatted)\(unit.suffix)"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = self.posixLocale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func byteCountString(_ bytes: Int64) -> String {
        let sign = bytes < 0 ? "-" : ""
        let absBytes = Double(Swift.abs(bytes))
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (1024 * 1024 * 1024, 1024 * 1024 * 1024, "GB"),
            (1024 * 1024, 1024 * 1024, "MB"),
            (1024, 1024, "KB"),
        ]

        for unit in units where absBytes >= unit.threshold {
            let scaled = absBytes / unit.divisor
            let format = scaled >= 10 || scaled.rounded(.towardZero) == scaled ? "%.0f" : "%.1f"
            let formatted = String(format: format, scaled)
            return "\(sign)\(formatted) \(unit.suffix)"
        }

        return "\(bytes) B"
    }

    // MARK: - Model labels

    public static func modelDisplayName(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return raw }

        let patterns = [
            #"(?:-|\s)\d{8}$"#,
            #"(?:-|\s)\d{4}-\d{2}-\d{2}$"#,
            #"\s\d{4}\s\d{4}$"#,
        ]

        for pattern in patterns {
            if let range = cleaned.range(of: pattern, options: .regularExpression) {
                cleaned.removeSubrange(range)
                break
            }
        }

        if let trailing = cleaned.range(of: #"[ \t-]+$"#, options: .regularExpression) {
            cleaned.removeSubrange(trailing)
        }

        return cleaned.isEmpty ? raw : cleaned
    }

    /// "Cost · tokens" detail line for a model row (legacy version minus the Codex
    /// "Research Preview" pricing-label lookup; the model parameter stays for 4a call-site
    /// compatibility).
    public static func modelCostDetail(
        _ model: String,
        costUSD: Double?,
        totalTokens: Int? = nil,
        currencyCode: String = "USD") -> String?
    {
        let costDetail = costUSD.map { self.currencyString($0, currencyCode: currencyCode) }
        let tokenDetail = totalTokens.map(self.tokenCountString)
        let parts = [costDetail, tokenDetail].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    // MARK: - Text utilities

    public static func truncatedSingleLine(_ text: String, max: Int = 80) -> String {
        let single = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > max else { return single }
        let idx = single.index(single.startIndex, offsetBy: max)
        return "\(single[..<idx])…"
    }
}
