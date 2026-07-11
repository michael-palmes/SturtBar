// UsageStoreCodexCostTests.swift — the Codex cost lane: trigger gating, provider gating,
// independence from Claude, and disable-wipe.

import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

@MainActor
struct UsageStoreCodexCostTests {
    /// Polls until `codexCostScanState == .idle` (wall-clock bounded; ~200×5ms = ~1s max).
    private func waitForCodexCostIdle(_ store: UsageStore) async {
        for _ in 0..<200 {
            if store.codexCostScanState == .idle { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("codex cost scan never settled")
    }

    private func recordingCodexScanner(_ recorder: CallRecorder) -> CostScanner {
        CostScanner(minimumGap: 60, scanOperation: { _, bypassGate, historyDays, _ in
            await recorder.recordScan(bypassGate: bypassGate, historyDays: historyDays)
            return makeCodexCostSnapshot()
        })
    }

    @Test
    func `menuOpen kicks a codex cost scan when codex and cost are enabled`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-cost-menuopen",
            codexScanner: self.recordingCodexScanner(recorder),
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true
        ts.settings.costUsageEnabled = true

        await ts.store.refresh(trigger: .menuOpen)
        await self.waitForCodexCostIdle(ts.store)

        #expect(await recorder.scanCount == 1)
        #expect(ts.store.codexCost != nil)
    }

    @Test
    func `codex cost scan is gated on the codex provider not claude`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-cost-gated",
            codexScanner: self.recordingCodexScanner(recorder),
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = false
        ts.settings.costUsageEnabled = true

        await ts.store.refresh(trigger: .manual)
        await self.waitForCodexCostIdle(ts.store)

        #expect(await recorder.scanCount == 0)
        #expect(ts.store.codexCost == nil)
    }

    @Test
    func `codex cost survives disabling claude`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-cost-survives-claude",
            codexScanner: self.recordingCodexScanner(recorder),
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true
        ts.settings.costUsageEnabled = true

        await ts.store.refresh(trigger: .menuOpen)
        await self.waitForCodexCostIdle(ts.store)
        #expect(ts.store.codexCost != nil)

        // Disabling Claude wipes the Claude cost lane but must leave Codex cost intact.
        ts.store.providerEnabledDidChange(.claude, enabled: false)
        #expect(ts.store.codexCost != nil)
    }

    @Test
    func `disabling codex clears codex cost`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-cost-disable",
            codexScanner: self.recordingCodexScanner(recorder),
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true
        ts.settings.costUsageEnabled = true

        await ts.store.refresh(trigger: .menuOpen)
        await self.waitForCodexCostIdle(ts.store)
        #expect(ts.store.codexCost != nil)

        ts.store.providerEnabledDidChange(.codex, enabled: false)
        #expect(ts.store.codexCost == nil)
    }

    @Test
    func `interval and launch do not kick codex cost scans`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-cost-interval",
            codexScanner: self.recordingCodexScanner(recorder),
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true
        ts.settings.costUsageEnabled = true

        await ts.store.refresh(trigger: .launch)
        await ts.store.refresh(trigger: .interval)
        await ts.store.refresh(trigger: .wake)
        await self.waitForCodexCostIdle(ts.store)

        #expect(await recorder.scanCount == 0)
    }
}
