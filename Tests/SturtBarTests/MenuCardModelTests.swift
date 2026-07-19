// MenuCardModelTests.swift — menu card Model derivation coverage (Phase 4a).
//
// Ported from legacy Tests/CodexBarTests/MenuCardModelTests.swift (Claude subset only — the
// provider-dispatch suites died with the providers) plus new-state coverage for the rebuild's
// auth/health rows, the cost skeleton, and the fixed-height section invariant.

import Foundation
import SturtBarCore
import Testing
@testable import SturtBar

struct MenuCardModelTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func window(
        used: Double,
        minutes: Int? = nil,
        resetsAt: Date? = nil,
        resetDescription: String? = nil) -> RateWindow
    {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    private func snapshot(
        primary: RateWindow,
        primaryWindowKind: ProviderUsageSnapshot.PrimaryWindowKind = .usage,
        secondary: RateWindow? = nil,
        opus: RateWindow? = nil,
        extraRateWindows: [NamedRateWindow] = [],
        modelWeeklyWindows: [NamedRateWindow] = [],
        providerCost: ProviderCostSnapshot? = nil,
        loginMethod: String? = "Claude Max") -> ProviderUsageSnapshot
    {
        ProviderUsageSnapshot(
            primary: primary,
            primaryWindowKind: primaryWindowKind,
            secondary: secondary,
            opus: opus,
            extraRateWindows: extraRateWindows,
            modelWeeklyWindows: modelWeeklyWindows,
            providerCost: providerCost,
            updatedAt: Self.now,
            loginMethod: loginMethod)
    }

    // MARK: - Metrics (ported Claude subset)

    @Test
    func `builds metrics using remaining percent`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 22, minutes: 300, resetsAt: now.addingTimeInterval(3000)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(3600)))

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            lastSuccessAt: now.addingTimeInterval(-300),
            quotaWarningThresholds: [.session: [50, 20], .weekly: [25, 0]],
            now: now))

        #expect(model.metrics.count == 2)
        #expect(model.metrics.first?.percent == 78)
        #expect(model.metrics.first?.percentLabel == "78% left")
        #expect(model.metrics.first?.isUsed == false)
        #expect(model.metrics.first?.warningMarkerPercents == [50, 20])
        #expect(model.metrics[1].warningMarkerPercents == [25])
        #expect(model.planText == "Max")
        #expect(model.subtitle.text(now: now).hasPrefix("Updated"))
        #expect(model.metrics[1].resetText(now: now)?.isEmpty == false)
    }

    @Test
    func `usageBarsShowUsed flips percent, label, and markers to the used axis`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 22, minutes: 300, resetsAt: now.addingTimeInterval(3000)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(3600)))

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            quotaWarningThresholds: [.session: [50, 20], .weekly: [25, 0]],
            usageBarsShowUsed: true,
            now: now))

        #expect(model.metrics.first?.percent == 22)
        #expect(model.metrics.first?.percentLabel == "22% used")
        #expect(model.metrics.first?.isUsed == true)
        // Markers mirror onto the consumption axis: 100 - threshold.
        #expect(model.metrics.first?.warningMarkerPercents == [50, 80])
        #expect(model.metrics[1].percent == 40)
        #expect(model.metrics[1].percentLabel == "40% used")
        #expect(model.metrics[1].warningMarkerPercents == [75])
    }

    @Test
    func `resetTimesShowAbsolute renders the clock form instead of a countdown`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 22, minutes: 300, resetsAt: now.addingTimeInterval(3000)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(3600)))

        let countdown = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))
            .metrics[1].resetText(now: now)
        let absolute = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot, resetTimesShowAbsolute: true, now: now))
            .metrics[1].resetText(now: now)

        #expect(countdown?.contains("Resets in") == true)
        #expect(absolute?.hasPrefix("Resets ") == true)
        #expect(absolute?.contains(":") == true) // an absolute clock time
        #expect(absolute?.contains("in ") == false)
        #expect(absolute != countdown)
    }

    @Test
    func `model weekly rows render after the tertiary slot and before extras`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 22, minutes: 300, resetsAt: now.addingTimeInterval(3000)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(3600)),
            opus: self.window(used: 10, minutes: 10080, resetsAt: now.addingTimeInterval(3600)),
            extraRateWindows: [NamedRateWindow(
                id: "claude-routines",
                title: "Daily Routines",
                window: self.window(used: 5, minutes: 10080))],
            modelWeeklyWindows: [NamedRateWindow(
                id: "model-weekly-fable",
                title: "Fable",
                window: self.window(used: 30, minutes: 10080, resetsAt: now.addingTimeInterval(7200)))])

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            quotaWarningThresholds: [.weekly: [25]],
            now: now))

        #expect(model.metrics.map(\.id)
            == ["primary", "secondary", "tertiary", "model-weekly-fable", "claude-routines"])
        let fable = model.metrics[3]
        #expect(fable.title == "Fable")
        #expect(fable.percent == 70)
        #expect(fable.warningMarkerPercents == [25])
        #expect(fable.resetText(now: now)?.isEmpty == false)
    }

    @Test
    func `showModelWeeklyLimits off filters the model weekly rows at display time`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 22, minutes: 300, resetsAt: now.addingTimeInterval(3000)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(3600)),
            modelWeeklyWindows: [NamedRateWindow(
                id: "model-weekly-fable",
                title: "Fable",
                window: self.window(used: 30, minutes: 10080, resetsAt: now.addingTimeInterval(7200)))])

        var input = UsageMenuCardView.Model.Input(now: now)
        input.snapshot = snapshot
        input.showModelWeeklyLimits = false

        let model = UsageMenuCardView.Model.make(input)
        #expect(model.metrics.map(\.id) == ["primary", "secondary"])
    }

    @Test
    func `claude model hides weekly when unavailable`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 2, resetsAt: now.addingTimeInterval(3600)),
            loginMethod: "Max")

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))

        #expect(model.metrics.count == 1)
        #expect(model.metrics.first?.title == "Session")
        #expect(model.planText == "Max")
    }

    @Test
    func `claude model includes routines bar when present`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 2, resetsAt: now.addingTimeInterval(3600)),
            secondary: self.window(used: 8, minutes: 10080, resetsAt: now.addingTimeInterval(7200)),
            opus: self.window(used: 16, minutes: 10080, resetsAt: now.addingTimeInterval(7800)),
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    window: self.window(used: 7, minutes: 10080, resetsAt: now.addingTimeInterval(9200))),
            ])

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))

        #expect(model.metrics.map(\.title) == ["Session", "Weekly", "Sonnet", "Daily Routines"])
    }

    @Test
    func `reset text falls back to server description without a date`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 10, resetDescription: "in 2 hours"))

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))

        #expect(model.metrics.first?.resetText(now: now) == "Resets in 2 hours")
    }

    @Test
    func `reset countdown is computed from the render-time date`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 10, minutes: 300, resetsAt: now.addingTimeInterval(50 * 60)))

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))
        let metric = model.metrics[0]

        #expect(metric.resetText(now: now) == "Resets in 50m")
        // Same model, later render tick: the string follows the timeline date, not Input.now.
        #expect(metric.resetText(now: now.addingTimeInterval(20 * 60)) == "Resets in 30m")
    }

    @Test
    func `weekly pace detail appears mid window`() throws {
        let now = Self.now
        // Half the 7-day window elapsed → expected 50% used; actual 40% → 10% in reserve.
        let weekly = self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(3.5 * 24 * 3600))
        let snapshot = self.snapshot(
            primary: self.window(used: 5, minutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: weekly)

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))
        let weeklyMetric = try #require(model.metrics.first { $0.id == "secondary" })

        #expect(weeklyMetric.detailLeftText == "10% in reserve")
        #expect(weeklyMetric.pacePercent == 50)
        #expect(weeklyMetric.paceOnTop)
    }

    @Test
    func `usageBarsShowUsed places the pace tip on the used axis`() throws {
        let now = Self.now
        // Quarter of each window elapsed → expected 25% used; actual 10% → 15% in reserve.
        let snapshot = self.snapshot(
            primary: self.window(used: 10, minutes: 300, resetsAt: now.addingTimeInterval(225 * 60)),
            secondary: self.window(used: 10, minutes: 10080, resetsAt: now.addingTimeInterval(5.25 * 24 * 3600)))

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            usageBarsShowUsed: true,
            now: now))
        let sessionMetric = try #require(model.metrics.first { $0.id == "primary" })
        let weeklyMetric = try #require(model.metrics.first { $0.id == "secondary" })

        // The tip marks expected-used (25%), not expected-remaining (75%).
        #expect(weeklyMetric.detailLeftText == "15% in reserve")
        #expect(weeklyMetric.pacePercent == 25)
        #expect(weeklyMetric.paceOnTop)
        #expect(sessionMetric.pacePercent == 25)
        #expect(sessionMetric.paceOnTop)
    }

    @Test
    func `usageBarsShowUsed keeps deficit state while flipping the tip`() throws {
        let now = Self.now
        // Quarter elapsed → expected 25% used; actual 40% → 15% in deficit.
        let snapshot = self.snapshot(
            primary: self.window(used: 5, minutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(5.25 * 24 * 3600)))

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            usageBarsShowUsed: true,
            now: now))
        let weeklyMetric = try #require(model.metrics.first { $0.id == "secondary" })

        // Deficit/reserve is a fact about usage, not the display axis: still red (paceOnTop == false).
        #expect(weeklyMetric.detailLeftText == "15% in deficit")
        #expect(weeklyMetric.pacePercent == 25)
        #expect(weeklyMetric.paceOnTop == false)
    }

    @Test
    func `spend limit primary renders spend detail instead of reset`() {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 27.5, resetDescription: "Spend limit: $5.50 / $20.00"),
            primaryWindowKind: .spendLimit,
            providerCost: ProviderCostSnapshot(
                used: 5.5,
                limit: 20,
                currencyCode: "USD",
                period: "Spend limit",
                updatedAt: now))

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            quotaWarningThresholds: [.session: [50, 20]],
            now: now))

        #expect(model.metrics.count == 1)
        #expect(model.metrics.first?.title == "Spend limit")
        #expect(model.metrics.first?.detailLeftText == "Spend limit: $5.50 / $20.00")
        #expect(model.metrics.first?.resetText(now: now) == nil)
        // Quota markers track usage windows only (warning-machine parity).
        #expect(model.metrics.first?.warningMarkerPercents.isEmpty == true)
        // The cap already renders as the primary bar — no duplicate extra-usage section.
        #expect(model.extraUsage == nil)
    }

    // MARK: - Plan line

    @Test
    func `plan line uses ClaudePlan naming`() {
        #expect(UsageMenuCardView.Model.planText(loginMethod: "Claude Max") == "Max")
        #expect(UsageMenuCardView.Model.planText(loginMethod: "Pro") == "Pro")
        #expect(UsageMenuCardView.Model.planText(loginMethod: "Custom Tier") == "Custom Tier")
        #expect(UsageMenuCardView.Model.planText(loginMethod: "  ") == nil)
        #expect(UsageMenuCardView.Model.planText(loginMethod: nil) == nil)
    }

    // MARK: - Subtitle

    @Test
    func `subtitle uses injected current time`() {
        let lastSuccessAt = Self.now
        let now = lastSuccessAt.addingTimeInterval(5 * 3600)
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 22)),
            lastSuccessAt: lastSuccessAt,
            now: now))

        #expect(model.subtitle == .updated(lastSuccessAt))
        #expect(model.subtitle.text(now: now) == UsageFormatter.updatedString(from: lastSuccessAt, now: now))
    }

    @Test
    func `subtitle shows refreshing only before the first snapshot`() {
        let now = Self.now
        let initial = UsageMenuCardView.Model.make(.init(snapshot: nil, isRefreshing: true, now: now))
        #expect(initial.subtitle == .refreshing)

        let withData = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 10)),
            isRefreshing: true,
            lastSuccessAt: now.addingTimeInterval(-60),
            now: now))
        #expect(withData.subtitle == .updated(now.addingTimeInterval(-60)))

        let neverFetched = UsageMenuCardView.Model.make(.init(snapshot: nil, now: now))
        #expect(neverFetched.subtitle == .neverFetched)
    }

    // MARK: - Placeholder metrics (nil snapshot)

    @Test
    func `nil snapshot reserves the standard claude trio`() {
        let model = UsageMenuCardView.Model.make(.init(snapshot: nil, now: Self.now))

        #expect(model.metrics.map(\.title) == ["Session", "Weekly", "Sonnet"])
        // A key path as the outermost #expect argument fails to compile (the macro
        // expansion treats it as a throwing call), so keep the closure form here.
        // swiftformat:disable:next preferKeyPath
        #expect(model.metrics.allSatisfy { $0.isPlaceholder })
        #expect(model.metrics.allSatisfy { $0.percentLabel == "—" })
        #expect(model.metrics.allSatisfy { $0.resetText(now: Self.now) == nil })
        #expect(model.planText == nil)
        #expect(model.extraUsage == nil)
    }

    // MARK: - Status strip (new states)

    @Test
    func `credentials missing shows sign-in action row`() {
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            auth: .credentialsMissing,
            now: Self.now))

        #expect(model.status == .credentialsMissing)
        #expect(model.status.text(now: Self.now) == "No light on this coast yet. Sign in to connect.")
        #expect(model.status.isError)
        #expect(model.status.action == .claudeSignIn)
        #expect(model.status.actionSymbolName == "apple.terminal")
        #expect(model.status.helpText == "Opens your terminal running claude /login to connect.")
    }

    @Test
    func `needs reauth shows sign-in action row with detail in the tooltip`() {
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 10)),
            auth: .needsReauth(message: "OAuth token refresh was rejected.", remedy: .signIn),
            now: Self.now))

        #expect(model.status == .needsReauth(detail: "OAuth token refresh was rejected.", remedy: .signIn))
        #expect(model.status.text(now: Self.now) == "Sign in to Claude Code")
        #expect(model.status.isError)
        #expect(model.status.action == .claudeSignIn)
        #expect(model.status.helpText == "OAuth token refresh was rejected.")
    }

    @Test
    func `needs reauth without message keeps the action row with a plain tooltip`() {
        let blank = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            auth: .needsReauth(message: "   ", remedy: .signIn),
            now: Self.now))

        #expect(blank.status == .needsReauth(detail: nil, remedy: .signIn))
        #expect(blank.status.text(now: Self.now) == "Sign in to Claude Code")
        #expect(blank.status.action == .claudeSignIn)
        #expect(blank.status.helpText == "Opens your terminal running claude /login to sign in again.")
    }

    @Test
    func `keychain access remedy shows reconnect action row`() {
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            auth: .needsReauth(message: "Claude Code's sign-in changed.", remedy: .keychainAccess),
            now: Self.now))

        #expect(model.status == .needsReauth(detail: "Claude Code's sign-in changed.", remedy: .keychainAccess))
        #expect(model.status.text(now: Self.now) == "Allow Keychain access to reconnect")
        #expect(model.status.isError)
        #expect(model.status.action == .claudeKeychainRetry)
        #expect(model.status.actionSymbolName == "key.horizontal")
        #expect(model.status.helpText == "Claude Code's sign-in changed.")
    }

    // MARK: - Reauth banner

    /// Claude auth states render the banner block: sign-in is always the primary remedy and the
    /// Keychain fallback line appears only for the keychain remedy (last-ditch by design).
    @Test
    func `claude auth states map to the reauth banner`() throws {
        let expired = UsageMenuCardView.Model.StatusLine
            .needsReauth(detail: "OAuth token refresh was rejected.", remedy: .signIn)
        let expiredBanner = try #require(expired.banner)
        #expect(expiredBanner.title == "Claude session expired")
        #expect(!expiredBanner.showsKeychainFallback)
        #expect(expiredBanner.helpText == "OAuth token refresh was rejected.")

        let keychain = UsageMenuCardView.Model.StatusLine
            .needsReauth(detail: "Keychain read blocked.", remedy: .keychainAccess)
        let keychainBanner = try #require(keychain.banner)
        #expect(keychainBanner.title == "Claude connection lost")
        #expect(keychainBanner.showsKeychainFallback)
        #expect(keychainBanner.helpText == "Keychain read blocked.")

        let missing = UsageMenuCardView.Model.StatusLine.credentialsMissing
        let missingBanner = try #require(missing.banner)
        #expect(missingBanner.title == "No light on this coast yet")
        #expect(!missingBanner.showsKeychainFallback)
    }

    @Test
    func `non-auth status lines render no banner`() {
        let lines: [UsageMenuCardView.Model.StatusLine] = [
            .empty,
            .rateLimited(until: Self.now.addingTimeInterval(90)),
            .retrying,
            .stale,
            .noProvidersEnabled,
            .codexCredentialsMissing,
            .codexSignInRequired,
            .codexApiKeyUnsupported,
        ]
        for line in lines {
            #expect(line.banner == nil)
        }
    }

    /// Banner presence and the fallback line both change the card height, so they must ride the
    /// shape fingerprint (mid-open auth flips defer their re-measure to menuDidClose).
    @Test
    func `reauth banner rides the shape fingerprint`() {
        func shape(auth: AuthState) -> MenuCardShape {
            MenuCardShape(model: UsageMenuCardView.Model.make(.init(
                snapshot: self.snapshot(primary: self.window(used: 10)),
                auth: auth,
                now: Self.now)))
        }

        let healthy = shape(auth: .ok)
        let expired = shape(auth: .needsReauth(message: "expired", remedy: .signIn))
        let keychain = shape(auth: .needsReauth(message: "blocked", remedy: .keychainAccess))
        #expect(healthy != expired)
        #expect(expired != keychain)
        // Detail text changes copy, not height: equal shapes must not re-measure.
        #expect(expired == shape(auth: .needsReauth(message: "other detail", remedy: .signIn)))
    }

    @Test
    func `non-auth status lines carry no action`() {
        let retrying = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 10)),
            health: .degraded(until: nil),
            now: Self.now))
        #expect(retrying.status.action == nil)
        #expect(retrying.status.actionSymbolName == nil)
        #expect(retrying.status.helpText == nil)
    }

    @Test
    func `rate limited shows render-time countdown`() {
        let now = Self.now
        let until = now.addingTimeInterval(12 * 60)
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 10)),
            health: .rateLimited(until: until),
            now: now))

        #expect(model.status == .rateLimited(until: until))
        #expect(model.status.text(now: now) == "Rate limited, retries in 12m")
        // Later render tick: the countdown follows the timeline date.
        #expect(model.status.text(now: now.addingTimeInterval(7 * 60)) == "Rate limited, retries in 5m")
        #expect(model.status.text(now: until.addingTimeInterval(1)) == "Rate limited, retrying now")
        #expect(model.status.isError)
    }

    @Test
    func `degraded shows subtle retrying line`() {
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 10)),
            health: .degraded(until: nil),
            now: Self.now))

        #expect(model.status == .retrying)
        #expect(model.status.text(now: Self.now) == "Refresh issue, retrying")
        #expect(!model.status.isError)
    }

    @Test
    func `stale data shows info line and healthy state shows none`() {
        let stale = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 10)),
            isStale: true,
            now: Self.now))
        #expect(stale.status == .stale)
        #expect(!stale.status.isError)

        let healthy = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 10)),
            now: Self.now))
        #expect(healthy.status == .empty)
        #expect(healthy.status.text(now: Self.now) == nil)
    }

    @Test
    func `auth problems outrank health problems in the status strip`() {
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            auth: .needsReauth(message: nil, remedy: .signIn),
            health: .rateLimited(until: Self.now.addingTimeInterval(600)),
            isStale: true,
            now: Self.now))

        #expect(model.status == .needsReauth(detail: nil, remedy: .signIn))
    }

    // MARK: - Extra usage section

    @Test
    func `claude extra usage labels monthly denominator as cap`() throws {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 0),
            providerCost: ProviderCostSnapshot(
                used: 5,
                limit: 20,
                currencyCode: "USD",
                period: "Monthly cap",
                updatedAt: now))

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))
        let extraUsage = try #require(model.extraUsage)

        #expect(extraUsage.title == "Extra usage")
        #expect(extraUsage.spendLine == "Monthly cap: $5.00 / $20.00")
        #expect(extraUsage.percentUsed == 25)
        #expect(extraUsage.percentLine == "25% used")
    }

    @Test
    func `extra usage without a limit renders as api spend`() throws {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 0),
            providerCost: ProviderCostSnapshot(used: 12, limit: 0, currencyCode: "USD", updatedAt: now))

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))
        let extraUsage = try #require(model.extraUsage)

        #expect(extraUsage.title == "API spend")
        #expect(extraUsage.spendLine == "Last 30 days: $12.00")
        #expect(extraUsage.percentUsed == nil)
        #expect(extraUsage.percentLine == nil)
    }

    // MARK: - Cost section

    @Test
    func `cost section shows a one-line cost summary`() throws {
        let now = Self.now
        let cost = CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 1.23,
            last30DaysTokens: 456,
            last30DaysCostUSD: 78.9,
            daily: [],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: self.snapshot(primary: self.window(used: 0)),
            cost: cost,
            costUsageEnabled: true,
            now: now))
        let section = try #require(model.costSection)

        #expect(!section.isSkeleton)
        #expect(!model.isCostSkeleton)
        #expect(section.summaryLine == "Cost  $1.23 today · $78.90 30d")
    }

    @Test
    func `cost skeleton shows scanning line while empty`() throws {
        let scanning = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            cost: nil,
            costUsageEnabled: true,
            costScanState: .scanning,
            now: Self.now))
        let scanningSection = try #require(scanning.costSection)
        #expect(scanning.isCostSkeleton)
        #expect(scanningSection.summaryLine == "Scanning session logs…")
        #expect(scanningSection.breakdown.isEmpty)

        let idle = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            cost: nil,
            costUsageEnabled: true,
            costScanState: .idle,
            now: Self.now))
        #expect(idle.isCostSkeleton)
        #expect(idle.costSection?.summaryLine == "No cost data yet")
    }

    @Test
    func `scan with existing data keeps the data not the skeleton`() {
        let cost = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.5,
            last30DaysTokens: 100,
            last30DaysCostUSD: 5,
            daily: [],
            updatedAt: Self.now)

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            cost: cost,
            costUsageEnabled: true,
            costScanState: .scanning,
            now: Self.now))

        #expect(!model.isCostSkeleton)
        #expect(model.costSection?.summaryLine == "Cost  $0.50 today · $5.00 30d")
    }

    @Test
    func `cost breakdown aggregates models across the window and caps rows`() throws {
        func entry(date: String, breakdowns: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: breakdowns.compactMap(\.costUSD).reduce(0, +),
                modelsUsed: breakdowns.map(\.modelName),
                modelBreakdowns: breakdowns)
        }
        let cost = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: 10,
            daily: [
                entry(date: "2026-06-09", breakdowns: [
                    .init(modelName: "claude-opus-4-6", costUSD: 2, totalTokens: 100),
                    .init(modelName: "claude-sonnet-4-5", costUSD: 0.5, totalTokens: 600),
                    .init(modelName: "claude-haiku-4-5", costUSD: 0.1, totalTokens: 50),
                ]),
                entry(date: "2026-06-10", breakdowns: [
                    .init(modelName: "claude-opus-4-6", costUSD: 3, totalTokens: 150),
                    .init(modelName: "claude-fable-5", costUSD: 0.05, totalTokens: 10),
                ]),
            ],
            updatedAt: Self.now)

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            cost: cost,
            costUsageEnabled: true,
            now: Self.now))
        let section = try #require(model.costSection)

        #expect(section.breakdown.count == UsageMenuCardView.CostSection.breakdownRowSlots)
        #expect(section.breakdown.map(\.id) == ["claude-opus-4-6", "claude-sonnet-4-5", "claude-haiku-4-5"])
        // Opus totals: $2 + $3 and 100 + 150 tokens across the two days.
        #expect(section.breakdown.first?.detail == "$5.00 · 250")
    }

    @Test
    func `cost section is configuration gated`() {
        let disabled = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            cost: nil,
            costUsageEnabled: false,
            costScanState: .scanning,
            now: Self.now))
        #expect(disabled.costSection == nil)
        #expect(!disabled.isCostSkeleton)
    }

    // MARK: - Fixed-height invariant

    /// Configuration constant, DATA varied across every axis (snapshot presence/shape, cost
    /// presence, scan state, auth, health, staleness): the slot list must never change.
    @Test
    func `sections depend on configuration not data`() {
        let now = Self.now
        let fullSnapshot = self.snapshot(
            primary: self.window(used: 22, minutes: 300, resetsAt: now.addingTimeInterval(3000)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            opus: self.window(used: 10, minutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            extraRateWindows: [
                NamedRateWindow(id: "claude-routines", title: "Daily Routines", window: self.window(used: 7)),
            ],
            providerCost: ProviderCostSnapshot(used: 5, limit: 20, currencyCode: "USD", updatedAt: now))
        let costData = CostUsageTokenSnapshot(
            sessionTokens: 1,
            sessionCostUSD: 0.1,
            last30DaysTokens: 2,
            last30DaysCostUSD: 0.2,
            daily: [],
            updatedAt: now)

        func input(_ mutate: (inout UsageMenuCardView.Model.Input) -> Void) -> UsageMenuCardView.Model.Input {
            var input = UsageMenuCardView.Model.Input(
                snapshot: nil,
                cost: nil,
                costUsageEnabled: true,
                quotaWarningThresholds: [.session: [50, 20], .weekly: [25]],
                now: now)
            mutate(&input)
            return input
        }

        let dataVariations: [UsageMenuCardView.Model.Input] = [
            input { _ in }, // nothing fetched yet
            input { $0.costScanState = .scanning },
            input { $0.snapshot = fullSnapshot; $0.cost = costData; $0.lastSuccessAt = now },
            input { $0.snapshot = fullSnapshot; $0.costScanState = .scanning },
            input { $0.auth = .credentialsMissing },
            input { $0.snapshot = fullSnapshot; $0.auth = .needsReauth(message: "expired", remedy: .signIn) },
            input {
                $0.snapshot = fullSnapshot
                $0.auth = .needsReauth(message: "keychain", remedy: .keychainAccess)
            },
            input { $0.snapshot = fullSnapshot; $0.health = .rateLimited(until: now.addingTimeInterval(600)) },
            input { $0.snapshot = fullSnapshot; $0.health = .degraded(until: nil) },
            input { $0.snapshot = fullSnapshot; $0.isStale = true; $0.isRefreshing = true },
        ]

        let expected: [UsageMenuCardView.Model.Section] = [.header, .status, .metrics, .cost]
        for variation in dataVariations {
            let model = UsageMenuCardView.Model.make(variation)
            #expect(model.sections == expected)
            // Within the cost slot, the breakdown block is likewise capped at its slot count.
            #expect((model.costSection?.breakdown.count ?? 0) <= UsageMenuCardView.CostSection.breakdownRowSlots)
        }

        // Changing CONFIGURATION (cost usage off) is what changes the slot list.
        let noCostConfig = [
            input { $0.costUsageEnabled = false },
            input { $0.costUsageEnabled = false; $0.snapshot = fullSnapshot; $0.cost = costData },
        ]
        for variation in noCostConfig {
            #expect(UsageMenuCardView.Model.make(variation).sections == [.header, .status, .metrics])
        }
    }

    /// The status strip never adds/removes a line — every state is exactly one line of text or
    /// the reserved blank, so auth/health flips mid-open cannot move the layout.
    @Test
    func `status strip text is always single line`() {
        let now = Self.now
        let lines: [UsageMenuCardView.Model.StatusLine] = [
            .empty,
            .credentialsMissing,
            .needsReauth(detail: nil, remedy: .signIn),
            .needsReauth(detail: "multi\nline\ndetail", remedy: .signIn),
            .needsReauth(detail: nil, remedy: .keychainAccess),
            .needsReauth(detail: "multi\nline\ndetail", remedy: .keychainAccess),
            .rateLimited(until: now.addingTimeInterval(90)),
            .retrying,
            .stale,
        ]
        for line in lines {
            let text = line.text(now: now)
            #expect(text?.contains("\n") != true)
        }
    }

    // MARK: - Weekly-pace exhausted-window guard

    /// A fully exhausted weekly window (0% remaining) must produce no pace text or tip — the same
    /// behaviour as legacy. Without the guard the metric would show "N% in deficit · Runs out now"
    /// and a red pace stripe on an already-empty bar.
    @Test
    func `exhausted weekly window shows no pace detail or tip`() {
        let now = Self.now
        let weekly = self.window(
            used: 100,
            minutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600))
        let snapshot = self.snapshot(
            primary: self.window(used: 50, minutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: weekly)

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: now))
        let weeklyMetric = model.metrics.first { $0.id == "secondary" }

        #expect(weeklyMetric != nil)
        #expect(weeklyMetric?.detailLeftText == nil)
        #expect(weeklyMetric?.detailRightText == nil)
        #expect(weeklyMetric?.pacePercent == nil)
    }

    // MARK: - Work-week (Mon-Fri) pacing

    @Test
    func `work-week pacing reshapes the weekly pace tip`() throws {
        let now = Self.now
        // Window start now-3d, reset now+4d (7-day window): three calendar days elapsed. The 5-day
        // expected is 20/40/60% (depending on how many were weekdays), never the flat-7-day 42.857%.
        let weekly = self.window(used: 80, minutes: 10080, resetsAt: now.addingTimeInterval(4 * 24 * 3600))
        let snapshot = self.snapshot(
            primary: self.window(used: 5, minutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: weekly)

        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, workDaysPerWeek: 5, now: now))
        let weeklyMetric = try #require(model.metrics.first { $0.id == "secondary" })

        // The tip must match a 5-day computation through the same local calendar the card uses.
        let pace = try #require(UsagePace.weekly(window: weekly, now: now, workWeek: WorkWeek()))
        let expectedTip: Double? = pace.stage == .onTrack ? nil : ((100 - pace.expectedUsedPercent) * 10).rounded() / 10
        #expect(weeklyMetric.pacePercent == expectedTip)
    }

    @Test
    func `work-week pacing gives the Sonnet row a tip and workday ticks`() throws {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 5, minutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(4 * 24 * 3600)),
            opus: self.window(used: 50, minutes: 10080, resetsAt: now.addingTimeInterval(4 * 24 * 3600)))

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            quotaWarningThresholds: [.weekly: [25]],
            workDaysPerWeek: 5,
            now: now))
        let sonnet = try #require(model.metrics.first { $0.id == "tertiary" })

        #expect(sonnet.title == "Sonnet")
        // The weekly warning threshold merged with the four workday ticks.
        #expect(sonnet.warningMarkerPercents == [20.0, 25.0, 40.0, 60.0, 80.0])
        // The Sonnet row gains a pace tip it never had before the migration.
        #expect(sonnet.pacePercent != nil)
    }

    @Test
    func `Sonnet row stays plain without work-week pacing`() throws {
        let now = Self.now
        let snapshot = self.snapshot(
            primary: self.window(used: 5, minutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: self.window(used: 40, minutes: 10080, resetsAt: now.addingTimeInterval(4 * 24 * 3600)),
            opus: self.window(used: 50, minutes: 10080, resetsAt: now.addingTimeInterval(4 * 24 * 3600)))

        // workDaysPerWeek defaults to nil (setting off): the Sonnet row is exactly as before.
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            quotaWarningThresholds: [.weekly: [25]],
            now: now))
        let sonnet = try #require(model.metrics.first { $0.id == "tertiary" })

        #expect(sonnet.title == "Sonnet")
        #expect(sonnet.warningMarkerPercents == [25.0]) // no workday ticks
        #expect(sonnet.pacePercent == nil) // no pace tip
    }

    @MainActor
    @Test
    func `makeInput maps the work-week setting to workDaysPerWeek`() {
        let test = makeTestStore(suiteName: "sturtbar-workweek-makeinput") { _, _ in
            throw CancellationError() // never invoked: makeInput only reads current store state
        }
        let now = Self.now

        test.settings.weeklyWorkWeekPacingEnabled = false
        #expect(UsageMenuCardView.Model.makeInput(
            store: test.store, settings: test.settings, now: now).workDaysPerWeek == nil)

        test.settings.weeklyWorkWeekPacingEnabled = true
        #expect(UsageMenuCardView.Model.makeInput(
            store: test.store, settings: test.settings, now: now).workDaysPerWeek == 5)
    }
}
