import Foundation
import Testing
@testable import SturtBarCore

/// Ported from CodexBarTests/ClaudePlanResolverTests.swift.
struct ClaudePlanTests {
    @Test
    func `oauth rate limit tier maps to branded plan`() {
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_pro") == "Claude Pro")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_team") == "Claude Team")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_enterprise") == "Claude Enterprise")
    }

    @Test
    func `oauth rate limit tier preserves the Max usage multiplier`() {
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_5x") == "Claude Max 5x")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_20x") == "Claude Max 20x")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "v2_default_claude_max_20x") == "Claude Max 20x")
        // A bare Max tier without a multiplier keeps the plain label.
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_max") == "Claude Max")
        // The multiplier must look like <integer>x.
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_max_turbo") == "Claude Max")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_team_5x") == "Claude Team")
    }

    @Test
    func `oauth subscription type overrides generic rate limit tier`() {
        #expect(
            ClaudePlan.oauthLoginMethod(subscriptionType: "pro", rateLimitTier: "default_claude_ai")
                == "Claude Pro")
        #expect(
            ClaudePlan.oauthLoginMethod(subscriptionType: "team", rateLimitTier: "default_claude_max_5x")
                == "Claude Team")
        #expect(ClaudePlan.oauthLoginMethod(subscriptionType: nil, rateLimitTier: "default_claude_ai") == nil)
    }

    @Test
    func `compatibility parser understands current labels`() {
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Max") == .max)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Max") == .max)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Pro") == .pro)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Ultra") == .ultra)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Team") == .team)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Enterprise") == .enterprise)
    }
}
