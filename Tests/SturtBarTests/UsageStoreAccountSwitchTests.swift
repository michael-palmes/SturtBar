import Foundation
import Synchronization
import Testing
@testable import SturtBar
@testable import SturtBarCore

@MainActor
struct UsageStoreAccountSwitchTests {
    @Test
    func `unreadable switch clears usage and saves the clearing before recovery`() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)
        let calls = Mutex(0)
        let generation = UUID()
        let ts = makeTestStore(suiteName: "switch-\(UUID())", persistence: persistence) { _, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { return makeUsageSnapshot(primaryUsedPercent: 80) }
            await ClaudeCredentialEvents.handler?(ClaudeCredentialContext(
                accountKey: "b", sourceFingerprint: "b", generation: generation, invalidatesUsage: true))
            if call == 2 {
                throw ClaudeUsageError.credentials(.claudeKeychainAccessRequired(
                    underlying: nil, reason: .promptsDisabled))
            }
            return makeUsageSnapshot(primaryUsedPercent: 10)
        }
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.usage?.primary.usedPercent == 80)
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.usage == nil)
        #expect(ts.store.lastSuccessAt == nil)
        #expect(persistence.loadNow()?.usage == nil)
        #expect(persistence.loadNow()?.claudeAccountKey == "b")
        guard case .needsReauth(_, .keychainAccess) = ts.store.auth else {
            Issue.record("Expected the existing reconnect action")
            return
        }
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.usage?.primary.usedPercent == 10)
        #expect(ts.store.auth == .ok)
        ts.store.shutdown()
    }

    @Test(arguments: ["a", "b", nil] as [String?])
    func `launch restores only compatible account usage`(current: String?) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)
        persistence.saveNow(StatePersistence.State(
            usage: makeUsageSnapshot(), cost: nil, claudeAccountKey: "a", savedAt: Date()))
        let ts = makeTestStore(
            suiteName: "restore-\(UUID())",
            persistence: persistence,
            accountKeyOperation: { current },
            fetch: { _, _ in makeUsageSnapshot() })
        await ts.store.loadPersistedState()
        #expect((ts.store.usage != nil) == (current != "b"))
        if current == "b" { #expect(persistence.loadNow()?.usage == nil) }
        ts.store.shutdown()
    }

    @Test
    func `disabled provider never reads account metadata or restores usage`() async {
        let reads = Mutex(0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)
        persistence.saveNow(StatePersistence.State(usage: makeUsageSnapshot(), cost: nil, savedAt: Date()))
        let ts = makeTestStore(
            suiteName: "disabled-\(UUID())",
            persistence: persistence,
            accountKeyOperation: { reads.withLock { $0 += 1 }; return "a" },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.claudeProviderEnabled = false
        await ts.store.loadPersistedState()
        await ts.store.refresh(trigger: .manual)
        #expect(reads.withLock { $0 } == 0)
        #expect(ts.store.usage == nil)
        ts.store.shutdown()
    }

    @Test
    func `late credential event and response cannot resurrect a disabled provider`() async {
        let started = TestLatch()
        let release = TestLatch()
        let ts = makeTestStore(suiteName: "disable-flight-\(UUID())") { _, _ in
            await started.open()
            await release.wait()
            await ClaudeCredentialEvents.handler?(ClaudeCredentialContext(
                accountKey: "b", sourceFingerprint: "b", generation: UUID(), invalidatesUsage: true))
            return makeUsageSnapshot()
        }
        let flight = Task { await ts.store.refresh(trigger: .manual) }
        await started.wait()
        ts.settings.claudeProviderEnabled = false
        ts.store.providerEnabledDidChange(.claude, enabled: false)
        await release.open()
        await flight.value
        #expect(ts.store.usage == nil)
        #expect(ts.store.claudeAccountKey == nil)
        ts.store.shutdown()
    }

    @Test(arguments: [false, true])
    func `quota baselines reset only for a changed account`(changed: Bool) async {
        let calls = Mutex(0)
        let ts = makeTestStore(suiteName: "quota-switch-\(UUID())") { _, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { return makeUsageSnapshot(primaryUsedPercent: 60) }
            await ClaudeCredentialEvents.handler?(ClaudeCredentialContext(
                accountKey: changed ? "b" : "a",
                sourceFingerprint: "renewed",
                generation: UUID(),
                invalidatesUsage: changed))
            return makeUsageSnapshot(primaryUsedPercent: 60)
        }
        ts.settings.quotaWarningNotificationsEnabled = true
        var crossings: [QuotaCrossing] = []
        ts.store.onQuotaThresholdCrossing = { _, crossing in crossings.append(crossing) }
        await ts.store.refresh(trigger: .manual)
        crossings.removeAll()
        await ts.store.refresh(trigger: .manual)
        #expect(crossings.count == (changed ? 1 : 0))
        ts.store.shutdown()
    }
}
