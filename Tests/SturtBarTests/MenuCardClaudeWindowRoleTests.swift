// MenuCardClaudeWindowRoleTests.swift — which row a Claude window lands in, from its length rather than its slot.

import Foundation
import SturtBarCore
import Testing
@testable import SturtBar

struct MenuCardClaudeWindowRoleTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A weekly-only reply promotes seven_day to primary; the card must not also title it "Session".
    @Test
    func `weekly only claude reply shows one weekly row and no session row`() throws {
        let json = """
        { "seven_day": { "utilization": 30, "resets_at": "2025-12-31T00:00:00.000Z" } }
        """
        let snapshot = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8), now: Self.now)
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: snapshot,
            quotaWarningThresholds: [.session: [50, 20], .weekly: [50, 20]],
            now: Self.now))

        #expect(model.metrics.map(\.title) == ["Weekly"])
        #expect(model.metrics.map(\.id) == ["secondary"])
    }

    @Test
    func `a promoted long window no other row shows keeps a weekly row`() throws {
        let json = """
        { "seven_day_oauth_apps": { "utilization": 12, "resets_at": "2025-12-31T00:00:00.000Z" } }
        """
        let snapshot = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8), now: Self.now)
        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: Self.now))

        #expect(model.metrics.map(\.title) == ["Weekly"])
        #expect(model.metrics.map(\.id) == ["primary"])
        #expect(model.metrics.first?.percentLabel == "88% left")
    }

    @Test
    func `a session window keeps its session row`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day": { "utilization": 30, "resets_at": "2025-12-31T00:00:00.000Z" }
        }
        """
        let snapshot = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8), now: Self.now)
        let model = UsageMenuCardView.Model.make(.init(snapshot: snapshot, now: Self.now))

        #expect(model.metrics.map(\.title) == ["Session", "Weekly"])
    }
}
