// UsagePaceText.swift — "in reserve / in deficit · runs out in …" pace labels for usage bars.
//
// Ported from legacy CodexBar/UsagePaceText.swift (Phase 4a). Rebuild changes:
//   - Provider parameter dropped: legacy gated session pace to codex/claude/ollama; Claude always
//     qualifies, so `sessionPace(window:now:)` keeps only the shared guards.
//   - `L(...)` localization → plain literals.
//   - The "Pace: …" one-line summaries (legacy text-only menu rows) are dropped; the card renders
//     left/right detail labels directly.

import Foundation
import SturtBarCore

enum UsagePaceText {
    struct WeeklyDetail {
        let leftLabel: String
        let rightLabel: String?
        let expectedUsedPercent: Double
        let stage: UsagePace.Stage
    }

    private enum DetailContext {
        case session
        case weekly
    }

    static func weeklyDetail(pace: UsagePace, now: Date) -> WeeklyDetail {
        WeeklyDetail(
            leftLabel: self.detailLeftLabel(for: pace),
            rightLabel: self.detailRightLabel(for: pace, context: .weekly, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        switch pace.stage {
        case .onTrack:
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(deltaValue)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(deltaValue)% in reserve"
        }
    }

    private static func detailRightLabel(for pace: UsagePace, context: DetailContext, now: Date) -> String? {
        let etaLabel: String?
        if pace.willLastToReset {
            etaLabel = "Lasts until reset"
        } else if let etaSeconds = pace.etaSeconds {
            let etaText = Self.durationText(seconds: etaSeconds, now: now)
            if context == .session {
                etaLabel = etaText == "now" ? "Projected empty now" : "Projected empty in \(etaText)"
            } else {
                etaLabel = etaText == "now" ? "Runs out now" : "Runs out in \(etaText)"
            }
        } else {
            etaLabel = nil
        }

        guard let runOutProbability = pace.runOutProbability else { return etaLabel }
        let roundedRisk = self.roundedRiskPercent(runOutProbability)
        let riskLabel = "≈ \(roundedRisk)% run-out risk"
        if let etaLabel {
            return "\(etaLabel) · \(riskLabel)"
        }
        return riskLabel
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    private static func roundedRiskPercent(_ probability: Double) -> Int {
        let percent = min(max(probability, 0), 1) * 100
        let rounded = (percent / 5).rounded() * 5
        return Int(rounded)
    }

    /// Session pace for the 5-hour window (legacy guards minus the provider gate).
    static func sessionPace(window: RateWindow, now: Date) -> UsagePace? {
        guard window.remainingPercent > 0 else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300) else { return nil }
        guard pace.expectedUsedPercent >= 3 else { return nil }
        return pace
    }

    static func sessionDetail(window: RateWindow, now: Date) -> WeeklyDetail? {
        guard let pace = sessionPace(window: window, now: now) else { return nil }
        return WeeklyDetail(
            leftLabel: Self.detailLeftLabel(for: pace),
            rightLabel: Self.detailRightLabel(for: pace, context: .session, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }
}
