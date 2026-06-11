// MenuCardView.swift — the SwiftUI usage card shown inside the NSMenu (Phase 4a).
//
// Ported from legacy CodexBar/MenuCardView.swift (61KB, ~20 providers) and trimmed to Claude:
// every UsageProvider branch, the Codex projection lanes, the OpenAI inline dashboard, credits,
// web-account email rows, and `L(...)` localization are gone. What survives: the card + Model +
// MetricRow structure, usage bars with percent/reset/pace lines, extra rate windows, the Claude
// extra-usage spend section, quota warning markers, and the plan line (ClaudePlan label).
//
// Two design constraints are NEW versus legacy (mandated by the rebuild plan):
//
// 1. FIXED-HEIGHT DISCIPLINE — NSMenu measures the card once at open; it cannot re-measure while
//    the menu is open, so mid-open data changes must never change the card's height.
//    `Model.sections` is the assertable contract: its contents depend ONLY on configuration
//    (cost-usage enabled), never on data, auth, or health. Per-slot height assumptions:
//      .header   2 fixed lines — headline title+plan line, footnote subtitle line; lineLimit(1).
//      .status   exactly 1 footnote line, ALWAYS rendered (a literal " " when there is nothing to
//                say) so auth/health transitions while the menu is open never change the height.
//      .metrics  rowCount × fixed 4-element row (body title + 6pt bar + footnote percent/reset
//                line + footnote detail line — the detail line is RESERVED, rendering " " when
//                there is no pace text, so pace appearing/disappearing never moves the layout).
//                rowCount derives from the snapshot's window shape (placeholder Session/Weekly/
//                Sonnet trio when snapshot is nil); shape is stable across refreshes of the same
//                account and known from the persisted snapshot at launch. The optional
//                extra-usage block rides in this slot and is likewise shape-derived (title +
//                bar + 1 line, bar present iff a positive limit exists).
//      .cost     fixed slots when enabled: header + 2 total lines + exactly
//                `CostSection.breakdownRowSlots` one-line model rows (blank-padded) + a CONSTANT
//                hint string — identical height for skeleton, empty, and data states.
//
// 2. RENDER-TIME COUNTDOWNS — the Model carries DATES (resetsAt, lastSuccessAt, rateLimited
//    until), not pre-formatted countdown strings. The view wraps its content in a single
//    `TimelineView(.periodic(from: .now, by: 60))` and formats "Resets in 2h 5m" / "Updated 3m
//    ago" / "Rate limited — retries in 12m" from the timeline date at render, so the open menu
//    ticks without any stored timers. Formatting lives in pure Model functions (testable with an
//    injected now). Pace detail strings are baked at Model.make from Input.now (legacy behavior;
//    they do not visibly tick) — their line is height-reserved either way.

import AppKit
import SturtBarCore
import SwiftUI

enum UsageMenuCardLayout {
    static let horizontalPadding: CGFloat = 20
    static let sectionTopPadding: CGFloat = 6
    static let sectionBottomPadding: CGFloat = 6
    static let headerLineSpacing: CGFloat = 4
    static let headerColumnSpacing: CGFloat = 12
    static let defaultWidth: CGFloat = 320
}

/// SwiftUI card used inside the NSMenu to mirror Apple's rich menu panels.
struct UsageMenuCardView: View {
    // MARK: - Model

    struct Model: Equatable {
        /// Fixed-height contract for Phase 4b: the slot list depends only on CONFIGURATION
        /// (cost usage enabled), never on data/auth/health. 4b sizes the hosting view once per
        /// menu open; equal `sections` ⇒ equal slot structure ⇒ stable height across mid-open
        /// data arrivals (see the metrics-shape caveat in the header comment).
        enum Section: String, CaseIterable, Equatable {
            case header
            case status
            case metrics
            case cost
        }

        /// Reset countdown inputs; the string is computed at render time from the timeline date.
        struct ResetInfo: Equatable {
            let resetsAt: Date?
            /// Server-provided textual fallback when no concrete date exists.
            let fallbackDescription: String?

            init(window: RateWindow) {
                self.resetsAt = window.resetsAt
                self.fallbackDescription = window.resetDescription
            }

            func text(now: Date) -> String? {
                // Reuse the core formatter by rebuilding a window shell around the stored fields.
                let shell = RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: self.resetsAt,
                    resetDescription: self.fallbackDescription)
                return UsageFormatter.resetLine(for: shell, style: .countdown, now: now)
            }
        }

        struct Metric: Identifiable, Equatable {
            let id: String
            let title: String
            /// Remaining percent, clamped 0...100 (the rebuild always displays remaining-style).
            let percent: Double
            let reset: ResetInfo?
            let detailLeftText: String?
            let detailRightText: String?
            let pacePercent: Double?
            let paceOnTop: Bool
            let warningMarkerPercents: [Double]
            /// True for the reserved no-data rows (empty bar, "—" percent label).
            let isPlaceholder: Bool

            init(
                id: String,
                title: String,
                percent: Double,
                reset: ResetInfo? = nil,
                detailLeftText: String? = nil,
                detailRightText: String? = nil,
                pacePercent: Double? = nil,
                paceOnTop: Bool = true,
                warningMarkerPercents: [Double] = [],
                isPlaceholder: Bool = false)
            {
                self.id = id
                self.title = title
                self.percent = percent
                self.reset = reset
                self.detailLeftText = detailLeftText
                self.detailRightText = detailRightText
                self.pacePercent = pacePercent
                self.paceOnTop = paceOnTop
                self.warningMarkerPercents = warningMarkerPercents
                self.isPlaceholder = isPlaceholder
            }

            var percentLabel: String {
                self.isPlaceholder ? "—" : String(format: "%.0f%% left", self.percent)
            }

            func resetText(now: Date) -> String? {
                self.reset?.text(now: now)
            }
        }

        /// Header second line ("Updated 3m ago" lives here; computed at render time).
        enum Subtitle: Equatable {
            case refreshing
            case updated(Date)
            case neverFetched

            func text(now: Date) -> String {
                switch self {
                case .refreshing:
                    "Refreshing…"
                case let .updated(date):
                    UsageFormatter.updatedString(from: date, now: now)
                case .neverFetched:
                    "Not fetched yet"
                }
            }
        }

        /// The always-present one-line status strip. `.empty` renders a blank reserved line so
        /// auth/health transitions never change the card height while the menu is open.
        enum StatusLine: Equatable {
            case empty
            /// AuthState.credentialsMissing — no Claude Code login on this machine.
            case credentialsMissing
            /// AuthState.needsReauth — re-auth row, optionally with a one-line error detail.
            case needsReauth(detail: String?)
            /// FetchHealth.rateLimited — countdown to the server-provided retry date.
            case rateLimited(until: Date)
            /// FetchHealth.degraded — subtle "retrying" line.
            case retrying
            /// Data present but older than the staleness threshold.
            case stale

            func text(now: Date) -> String? {
                switch self {
                case .empty:
                    return nil
                case .credentialsMissing:
                    // Empty state (BRAND.md §3.3), kept actionable: the command stays.
                    return "No light on this coast yet. Run `claude` to connect."
                case let .needsReauth(detail):
                    guard let detail else { return "Re-authenticate in Claude Code." }
                    return "Re-authenticate in Claude Code: \(UsageFormatter.truncatedSingleLine(detail))"
                case let .rateLimited(until):
                    let countdown = UsageFormatter.resetCountdownDescription(from: until, now: now)
                    return countdown == "now"
                        ? "Rate limited, retrying now"
                        : "Rate limited, retries \(countdown)"
                case .retrying:
                    return "Refresh issue, retrying"
                case .stale:
                    return "Data may be out of date"
                }
            }

            /// Error (red) styling for actionable problems; secondary for transient/info lines.
            var isError: Bool {
                switch self {
                case .credentialsMissing, .needsReauth, .rateLimited:
                    true
                case .empty, .retrying, .stale:
                    false
                }
            }

            /// Full untruncated detail for the click-to-copy overlay.
            var copyText: String? {
                if case let .needsReauth(detail) = self { return detail }
                return nil
            }
        }

        /// Claude "Extra usage" spend block (snapshot.providerCost, usage-kind primaries only —
        /// spend-limit primaries already render the same data as the primary bar).
        struct ExtraUsageSection: Equatable {
            let title: String
            let percentUsed: Double?
            let spendLine: String
            let percentLine: String?
        }

        let planText: String?
        let subtitle: Subtitle
        let status: StatusLine
        let metrics: [Metric]
        let extraUsage: ExtraUsageSection?
        /// nil iff cost usage is disabled (the section is configuration-gated, never data-gated).
        let costSection: CostSection?

        /// The fixed-height slot list — configuration-derived only (assertable; see tests).
        var sections: [Section] {
            var sections: [Section] = [.header, .status, .metrics]
            if self.costSection != nil {
                sections.append(.cost)
            }
            return sections
        }

        var isCostSkeleton: Bool {
            self.costSection?.isSkeleton ?? false
        }
    }

    // MARK: - View

    let model: Model
    let width: CGFloat

    init(model: Model, width: CGFloat = UsageMenuCardLayout.defaultWidth) {
        self.model = model
        self.width = width
    }

    var body: some View {
        // Single periodic timeline drives every countdown/updated-ago string; one re-render per
        // minute while visible, consistent `now` across all rows, no stored timers.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            self.content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        // DEBUG probe for live verification: counts content evaluations (ticks + model swaps) so
        // logs can prove the open menu ticks per minute and the closed menu renders nothing.
        #if DEBUG
        MenuCardRenderProbe.recordRender(now: now)
        #endif
        return VStack(alignment: .leading, spacing: 6) {
            UsageMenuCardHeaderView(model: self.model, now: now)

            Divider()

            UsageMenuCardStatusStripView(status: self.model.status, now: now)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(self.model.metrics) { metric in
                    MetricRow(metric: metric, now: now)
                }
                if let extraUsage = self.model.extraUsage {
                    ExtraUsageContent(section: extraUsage)
                }
            }

            if let costSection = self.model.costSection {
                Divider()
                CostSectionContent(section: costSection)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, UsageMenuCardLayout.sectionTopPadding)
        .padding(.bottom, UsageMenuCardLayout.sectionBottomPadding)
        .frame(width: self.width, alignment: .leading)
    }
}

// MARK: - Header (slot: 2 fixed lines)

private struct UsageMenuCardHeaderView: View {
    let model: UsageMenuCardView.Model
    let now: Date
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text("Claude").font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer()
                if let plan = self.model.planText {
                    Text(plan)
                        .font(.subheadline)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
            Text(self.model.subtitle.text(now: self.now))
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Status strip (slot: exactly 1 footnote line, always rendered)

private struct UsageMenuCardStatusStripView: View {
    let status: UsageMenuCardView.Model.StatusLine
    let now: Date
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        let text = self.status.text(now: self.now)
        // The literal-space fallback reserves the line when there is nothing to report.
        Text(text ?? " ")
            .font(.footnote)
            .foregroundStyle(
                self.status.isError
                    ? MenuHighlightStyle.error(self.isHighlighted)
                    : MenuHighlightStyle.secondary(self.isHighlighted))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if let copyText = self.status.copyText {
                    ClickToCopyOverlay(copyText: copyText)
                }
            }
            .accessibilityHidden(text == nil)
    }
}

// MARK: - Metric row (slot element: title + 6pt bar + percent/reset line + reserved detail line)

private struct MetricRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let now: Date
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.metric.title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            UsageProgressBar(
                percent: self.metric.isPlaceholder ? 0 : self.metric.percent,
                tint: ClaudeBranding.color,
                accessibilityLabel: "Usage remaining",
                accessibilityValueOverride: self.metric.isPlaceholder ? "no data" : nil,
                pacePercent: self.metric.pacePercent,
                paceOnTop: self.metric.paceOnTop,
                warningMarkerPercents: self.metric.warningMarkerPercents)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.metric.percentLabel)
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    if let resetText = self.metric.resetText(now: self.now) {
                        Text(resetText)
                            .font(.footnote)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }
                }
                // Reserved detail line: always rendered so pace text appearing between refreshes
                // never changes the row height while the menu is open.
                HStack(alignment: .firstTextBaseline) {
                    Text(self.metric.detailLeftText ?? " ")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                        .lineLimit(1)
                    Spacer()
                    if let detailRight = self.metric.detailRightText {
                        Text(detailRight)
                            .font(.footnote)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Extra usage (shape-derived block: title + optional bar + 1 line)

private struct ExtraUsageContent: View {
    let section: UsageMenuCardView.Model.ExtraUsageSection
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.section.title)
                .font(.body)
                .fontWeight(.medium)
            if let percentUsed = self.section.percentUsed {
                UsageProgressBar(
                    percent: percentUsed,
                    tint: ClaudeBranding.color,
                    accessibilityLabel: "Extra usage spent")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(self.section.spendLine)
                    .font(.footnote)
                    .lineLimit(1)
                Spacer()
                if let percentLine = self.section.percentLine {
                    Text(percentLine)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Model factory

extension UsageMenuCardView.Model {
    /// Direct store-state inputs — no provider params, no projections (legacy routed Codex
    /// through StatusItemController+MenuCardModel; the rebuild derives straight from the
    /// snapshot). Phase 4b assembles this from UsageStore + SettingsStore on menu open.
    struct Input {
        var snapshot: ClaudeUsageSnapshot?
        var cost: CostUsageTokenSnapshot?
        var auth: AuthState = .ok
        var health: FetchHealth = .ok
        var isRefreshing = false
        var isStale = false
        /// Local-clock time of the last successful fetch (UsageStore.lastSuccessAt) — the
        /// "Updated Xm ago" source.
        var lastSuccessAt: Date?
        var costUsageEnabled = false
        var costScanState: CostScanState = .idle
        /// Marker thresholds per window; callers pass [] / omit a window to hide its markers
        /// (legacy `quotaWarningMarkersVisible` resolution happens at the call site).
        var quotaWarningThresholds: [QuotaWindow: [Int]] = [:]
        /// Workday boundary markers on the weekly bar; nil = feature off (no setting yet in the
        /// rebuild — kept so the marker math stays ported and tested).
        var workDaysPerWeek: Int?
        var now: Date
    }

    static func make(_ input: Input) -> UsageMenuCardView.Model {
        UsageMenuCardView.Model(
            planText: self.planText(loginMethod: input.snapshot?.loginMethod),
            subtitle: self.subtitle(input: input),
            status: self.statusLine(input: input),
            metrics: self.metrics(input: input),
            extraUsage: extraUsageSection(snapshot: input.snapshot),
            costSection: costSection(input: input))
    }

    // MARK: Plan

    /// ClaudePlan owns plan naming: "Claude Max" → "Max"; unknown strings pass through trimmed.
    static func planText(loginMethod: String?) -> String? {
        guard let loginMethod else { return nil }
        let trimmed = loginMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ClaudePlan.fromCompatibilityLoginMethod(trimmed)?.compactLoginMethod ?? trimmed
    }

    // MARK: Subtitle

    private static func subtitle(input: Input) -> Subtitle {
        if input.isRefreshing, input.snapshot == nil {
            return .refreshing
        }
        if let lastSuccessAt = input.lastSuccessAt {
            return .updated(lastSuccessAt)
        }
        return .neverFetched
    }

    // MARK: Status strip

    /// Priority: auth problems (actionable) > rate limit (hard gate with a date) > degraded
    /// (transient) > staleness (informational) > empty.
    private static func statusLine(input: Input) -> StatusLine {
        switch input.auth {
        case .credentialsMissing:
            return .credentialsMissing
        case let .needsReauth(message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .needsReauth(detail: (detail?.isEmpty ?? true) ? nil : detail)
        case .ok:
            break
        }
        switch input.health {
        case let .rateLimited(until):
            return .rateLimited(until: until)
        case .degraded:
            return .retrying
        case .ok:
            break
        }
        return input.isStale ? .stale : .empty
    }

    // MARK: Metrics

    /// Shared display-title constants for the standard Claude quota windows.
    /// Used in both `placeholderMetrics()` and the data-derived path so the strings stay in sync.
    enum MetricTitles {
        static let session = "Session"
        static let weekly = "Weekly"
        static let sonnet = "Sonnet"
    }

    private static func metrics(input: Input) -> [Metric] {
        guard let snapshot = input.snapshot else {
            return self.placeholderMetrics()
        }

        var metrics: [Metric] = []
        metrics.append(Self.primaryMetric(snapshot: snapshot, input: input))

        if let weekly = snapshot.secondary {
            // Guard matches legacy: no pace text/tip when the window is fully exhausted (0% left),
            // so a completely used weekly quota shows a plain empty bar without deficit labels.
            let pace: UsagePace? = weekly.remainingPercent > 0
                ? UsagePace.weekly(window: weekly, now: input.now, defaultWindowMinutes: 10080)
                .flatMap { $0.expectedUsedPercent >= 3 ? $0 : nil }
                : nil
            let paceDetail = Self.weeklyPaceDetail(window: weekly, now: input.now, pace: pace)
            metrics.append(Metric(
                id: "secondary",
                title: MetricTitles.weekly,
                percent: Self.clamped(weekly.remainingPercent),
                reset: ResetInfo(window: weekly),
                detailLeftText: paceDetail?.leftLabel,
                detailRightText: paceDetail?.rightLabel,
                pacePercent: paceDetail?.pacePercent,
                paceOnTop: paceDetail?.paceOnTop ?? true,
                warningMarkerPercents: Self.weeklyMarkerPercents(input: input, windowMinutes: weekly.windowMinutes)))
        }

        if let opus = snapshot.opus {
            // Legacy labels the model-specific weekly window "Sonnet" (claude opusLabel) and
            // applies the weekly thresholds without workday markers.
            metrics.append(Metric(
                id: "tertiary",
                title: MetricTitles.sonnet,
                percent: Self.clamped(opus.remainingPercent),
                reset: ResetInfo(window: opus),
                warningMarkerPercents: Self.warningMarkerPercents(
                    thresholds: input.quotaWarningThresholds[.weekly],
                    showUsed: false)))
        }

        for namedWindow in snapshot.extraRateWindows {
            metrics.append(Metric(
                id: namedWindow.id,
                title: namedWindow.title,
                percent: Self.clamped(namedWindow.window.remainingPercent),
                reset: ResetInfo(window: namedWindow.window)))
        }

        return metrics
    }

    private static func primaryMetric(snapshot: ClaudeUsageSnapshot, input: Input) -> Metric {
        let primary = snapshot.primary
        switch snapshot.primaryWindowKind {
        case .usage:
            let paceDetail = Self.sessionPaceDetail(window: primary, now: input.now)
            return Metric(
                id: "primary",
                title: MetricTitles.session,
                percent: Self.clamped(primary.remainingPercent),
                reset: ResetInfo(window: primary),
                detailLeftText: paceDetail?.leftLabel,
                detailRightText: paceDetail?.rightLabel,
                pacePercent: paceDetail?.pacePercent,
                paceOnTop: paceDetail?.paceOnTop ?? true,
                warningMarkerPercents: Self.warningMarkerPercents(
                    thresholds: input.quotaWarningThresholds[.session],
                    showUsed: false))
        case .spendLimit:
            // Spend-limit pseudo-window: the bar shows cap utilization; the spend line
            // ("Spend limit: $X / $Y" from the service) goes on the reserved detail line —
            // NOT through ResetInfo, which would prefix it with "Resets". No quota markers:
            // the warning machine ignores spend-limit primaries (QuotaWarnings parity).
            return Metric(
                id: "primary",
                title: "Spend limit",
                percent: Self.clamped(primary.remainingPercent),
                detailLeftText: primary.resetDescription)
        }
    }

    /// Reserved no-data rows: the standard Claude trio keeps the metrics slot at its expected
    /// height until the first snapshot (or persisted cache) arrives.
    private static func placeholderMetrics() -> [Metric] {
        [
            ("primary", MetricTitles.session),
            ("secondary", MetricTitles.weekly),
            ("tertiary", MetricTitles.sonnet),
        ].map { id, title in
            Metric(id: id, title: title, percent: 0, isPlaceholder: true)
        }
    }

    // MARK: Pace details

    struct PaceDetail {
        let leftLabel: String
        let rightLabel: String?
        let pacePercent: Double?
        let paceOnTop: Bool
    }

    static func sessionPaceDetail(window: RateWindow, now: Date) -> PaceDetail? {
        guard let detail = UsagePaceText.sessionDetail(window: window, now: now) else { return nil }
        return Self.paceDetail(detail: detail, window: window)
    }

    static func weeklyPaceDetail(window: RateWindow, now: Date, pace: UsagePace?) -> PaceDetail? {
        guard let pace else { return nil }
        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)
        return Self.paceDetail(detail: detail, window: window)
    }

    /// Remaining-style mapping of the legacy pace projection (the rebuild has no "show used"
    /// toggle): the bar tip marks expected REMAINING percent; on-track hides the tip.
    ///
    /// The tip percent is quantized to 0.1% (≈0.3px at card width): expected-used is a
    /// continuous function of `now`, so without quantization two derives milliseconds apart
    /// produce unequal Models and defeat the Equatable rootView gate (Phase 4b re-make gating).
    private static func paceDetail(detail: UsagePaceText.WeeklyDetail, window: RateWindow) -> PaceDetail? {
        let expectedUsed = detail.expectedUsedPercent
        let actualUsed = window.usedPercent
        let expectedPercent = 100 - expectedUsed
        let actualPercent = 100 - actualUsed
        if expectedPercent.isFinite == false || actualPercent.isFinite == false { return nil }
        let paceOnTop = actualUsed <= expectedUsed
        let pacePercent: Double? = if detail.stage == .onTrack {
            nil
        } else {
            (expectedPercent * 10).rounded() / 10
        }
        return PaceDetail(
            leftLabel: detail.leftLabel,
            rightLabel: detail.rightLabel,
            pacePercent: pacePercent,
            paceOnTop: paceOnTop)
    }

    // MARK: Shared

    static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

// MARK: - Previews

#if DEBUG
extension UsageMenuCardView.Model.Input {
    fileprivate static func preview(now: Date = .init()) -> Self {
        let snapshot = ClaudeUsageSnapshot(
            primary: RateWindow(
                usedPercent: 36,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 3600 + 300),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 58,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            opus: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    window: RateWindow(
                        usedPercent: 7,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                        resetDescription: nil)),
            ],
            providerCost: ProviderCostSnapshot(
                used: 5.5,
                limit: 20,
                currencyCode: "USD",
                period: "Monthly cap",
                updatedAt: now),
            updatedAt: now,
            loginMethod: "Claude Max")
        let cost = CostUsageTokenSnapshot(
            sessionTokens: 2_400_000,
            sessionCostUSD: 4.31,
            last30DaysTokens: 61_500_000,
            last30DaysCostUSD: 96.78,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-06-10",
                    inputTokens: 1_200_000,
                    outputTokens: 140_000,
                    totalTokens: 2_400_000,
                    costUSD: 4.31,
                    modelsUsed: ["claude-opus-4-6", "claude-sonnet-4-5"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-opus-4-6",
                            costUSD: 3.51,
                            totalTokens: 1_500_000),
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-sonnet-4-5",
                            costUSD: 0.80,
                            totalTokens: 900_000),
                    ]),
            ],
            updatedAt: now)
        return Self(
            snapshot: snapshot,
            cost: cost,
            lastSuccessAt: now.addingTimeInterval(-4 * 60),
            costUsageEnabled: true,
            quotaWarningThresholds: [.session: [50, 20], .weekly: [25]],
            now: now)
    }
}

#Preview("Full data") {
    UsageMenuCardView(model: .make(.preview()))
        .padding(.vertical, 8)
}

#Preview("Needs re-auth") {
    var input = UsageMenuCardView.Model.Input.preview()
    input.auth = .needsReauth(message: "OAuth token refresh was rejected (invalid_grant).")
    input.isStale = true
    return UsageMenuCardView(model: .make(input))
        .padding(.vertical, 8)
}

#Preview("Credentials missing") {
    let now = Date()
    let input = UsageMenuCardView.Model.Input(
        snapshot: nil,
        cost: nil,
        auth: .credentialsMissing,
        costUsageEnabled: true,
        quotaWarningThresholds: [.session: [50, 20], .weekly: [25]],
        now: now)
    return UsageMenuCardView(model: .make(input))
        .padding(.vertical, 8)
}

#Preview("Scanning + rate limited") {
    var input = UsageMenuCardView.Model.Input.preview()
    input.cost = nil
    input.costScanState = .scanning
    input.health = .rateLimited(until: Date().addingTimeInterval(12 * 60))
    return UsageMenuCardView(model: .make(input))
        .padding(.vertical, 8)
}

#Preview("Spend-limit primary") {
    let now = Date()
    let snapshot = ClaudeUsageSnapshot(
        primary: RateWindow(
            usedPercent: 72,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "Spend limit: $144.00 / $200.00"),
        primaryWindowKind: .spendLimit,
        secondary: nil,
        opus: nil,
        extraRateWindows: [],
        providerCost: ProviderCostSnapshot(
            used: 144,
            limit: 200,
            currencyCode: "USD",
            period: "Monthly cap",
            updatedAt: now),
        updatedAt: now,
        loginMethod: nil)
    let input = UsageMenuCardView.Model.Input(
        snapshot: snapshot,
        cost: nil,
        costUsageEnabled: false,
        now: now)
    return UsageMenuCardView(model: .make(input))
        .padding(.vertical, 8)
}

#Preview("0% and 100% extremes") {
    let now = Date()
    // 0% remaining (exhausted) — should show no pace tip/text (guard fix)
    // 100% remaining — pace marker at right edge
    let snapshot = ClaudeUsageSnapshot(
        primary: RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(4 * 3600),
            resetDescription: nil),
        secondary: RateWindow(
            usedPercent: 100,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil),
        opus: RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil),
        extraRateWindows: [],
        providerCost: nil,
        updatedAt: now,
        loginMethod: "Claude Max")
    let input = UsageMenuCardView.Model.Input(
        snapshot: snapshot,
        lastSuccessAt: now.addingTimeInterval(-30),
        quotaWarningThresholds: [.session: [50, 20], .weekly: [25]],
        now: now)
    return UsageMenuCardView(model: .make(input))
        .padding(.vertical, 8)
}

#Preview("Longest strings (deficit + run-out risk)") {
    let now = Date()
    // Far-ahead session: "Projected empty in 45m" with run-out risk; weekly deficit.
    let snapshot = ClaudeUsageSnapshot(
        primary: RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil),
        secondary: RateWindow(
            usedPercent: 65,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(3.5 * 24 * 3600),
            resetDescription: nil),
        opus: nil,
        extraRateWindows: [],
        providerCost: nil,
        updatedAt: now,
        loginMethod: "Claude Max")
    let input = UsageMenuCardView.Model.Input(
        snapshot: snapshot,
        lastSuccessAt: now.addingTimeInterval(-60),
        quotaWarningThresholds: [.session: [50, 20], .weekly: [25]],
        now: now)
    return UsageMenuCardView(model: .make(input))
        .padding(.vertical, 8)
}
#endif
