import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageCodexLongContextTests {
    @Test
    func `busy days of normal turns stay at base rates`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 24)
        try env.writeSession("2026/09/24/rollout-busy.jsonl", [
            env.turnContext(model: "gpt-5.5"),
            env.tokenCount(ts: env.isoString(for: day), model: "gpt-5.5", input: 200_000, cached: 0, output: 1000),
            env.tokenCount(
                ts: env.isoString(for: day.addingTimeInterval(1)),
                model: "gpt-5.5",
                input: 200_000,
                cached: 0,
                output: 1000),
        ])

        let entry = try #require(env.loadCodex(since: day, until: day, now: day).data.first)
        let expected = (400_000.0 * 5e-6) + (2000.0 * 3e-5)
        #expect(abs((entry.costUSD ?? 0) - expected) < 1e-9)
    }

    @Test
    func `a single long turn uses the long context rates`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 24)
        try env.writeSession("2026/09/24/rollout-long.jsonl", [
            env.turnContext(model: "gpt-5.5"),
            env.tokenCount(
                ts: env.isoString(for: day),
                model: "gpt-5.5",
                input: 300_000,
                cached: 100_000,
                output: 1000),
            env.tokenCount(
                ts: env.isoString(for: day.addingTimeInterval(1)),
                model: "gpt-5.5",
                input: 10000,
                cached: 0,
                output: 100),
        ])

        let entry = try #require(env.loadCodex(since: day, until: day, now: day).data.first)
        let longTurn = (200_000.0 * 1e-5) + (100_000.0 * 1e-6) + (1000.0 * 4.5e-5)
        let shortTurn = (10000.0 * 5e-6) + (100.0 * 3e-5)
        #expect(abs((entry.costUSD ?? 0) - (longTurn + shortTurn)) < 1e-9)
        #expect(entry.inputTokens == 310_000)
    }

    @Test
    func `cached tokens take the larger of the two fields`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 24)
        let info: [String: Any] = [
            "last_token_usage": [
                "input_tokens": 1000,
                "cached_input_tokens": 100,
                "cache_read_input_tokens": 400,
                "output_tokens": 0,
            ],
        ]
        try env.writeSession("2026/09/24/rollout-cached.jsonl", [
            env.turnContext(model: "gpt-5.1-codex"),
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day),
                "payload": ["type": "token_count", "info": info],
            ],
        ])

        let entry = try #require(env.loadCodex(since: day, until: day, now: day).data.first)
        #expect(entry.cacheReadTokens == 400)
    }

    @Test
    func `saving the codex cache removes the v1 file`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }
        let dir = env.cacheRoot.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("codex-v1.json")
        try Data("{}".utf8).write(to: legacy)

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 24)
        try env.writeSession("2026/09/24/rollout-any.jsonl", [
            env.tokenCount(ts: env.isoString(for: day), model: "gpt-5.1-codex", input: 10, cached: 0, output: 1),
        ])
        _ = try env.loadCodex(since: day, until: day, now: day)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("codex-v2.json").path))
    }
}
