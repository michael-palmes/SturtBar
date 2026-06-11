// ClaudeUsageClientTests.swift — single-flight coalescing + join-or-upgrade policy.

import Foundation
import Synchronization
import Testing
@testable import SturtBar
@testable import SturtBarCore

struct ClaudeUsageClientTests {
    @Test
    func `concurrent fetches coalesce onto one flight and share the result`() async throws {
        let recorder = CallRecorder()
        let started = TestLatch()
        let release = TestLatch()
        let client = ClaudeUsageClient(fetchOperation: { interaction, phase in
            await recorder.recordFetch(interaction: interaction, phase: phase)
            await started.open()
            await release.wait()
            return makeUsageSnapshot()
        })

        let first = Task { try await client.fetch(interaction: .background) }
        await started.wait()
        let second = Task { try await client.fetch(interaction: .background) }
        for _ in 0..<200 {
            await Task.yield()
        }
        await release.open()

        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value
        #expect(firstSnapshot == secondSnapshot)
        #expect(await recorder.fetchCount == 1)
    }

    @Test
    func `background joiners share the in-flight failure`() async {
        let recorder = CallRecorder()
        let started = TestLatch()
        let release = TestLatch()
        let client = ClaudeUsageClient(fetchOperation: { interaction, phase in
            await recorder.recordFetch(interaction: interaction, phase: phase)
            await started.open()
            await release.wait()
            throw ClaudeUsageError.fetch(.networkError(URLError(.timedOut)))
        })

        let first = Task { try await client.fetch(interaction: .background) }
        await started.wait()
        let second = Task { try await client.fetch(interaction: .background) }
        for _ in 0..<200 {
            await Task.yield()
        }
        await release.open()

        await #expect(throws: ClaudeUsageError.self) { try await first.value }
        await #expect(throws: ClaudeUsageError.self) { try await second.value }
        #expect(await recorder.fetchCount == 1)
    }

    @Test
    func `user-initiated arrival reruns after a failed background flight`() async throws {
        let recorder = CallRecorder()
        let started = TestLatch()
        let release = TestLatch()
        // First (background) call fails after being held open; the upgrade rerun succeeds.
        let callIndex = Mutex(0)
        let client = ClaudeUsageClient(fetchOperation: { interaction, phase in
            await recorder.recordFetch(interaction: interaction, phase: phase)
            let index = callIndex.withLock { value -> Int in
                value += 1
                return value
            }
            if index == 1 {
                await started.open()
                await release.wait()
                throw ClaudeUsageError.credentials(.keychainError(-128)) // gated/denied
            }
            return makeUsageSnapshot()
        })

        let background = Task { try await client.fetch(interaction: .background) }
        await started.wait()
        let user = Task { try await client.fetch(interaction: .userInitiated) }
        for _ in 0..<200 {
            await Task.yield()
        }
        await release.open()

        // The background caller gets the failure; the user gesture gets a fresh snapshot from a
        // rerun that carries user-initiated (gate-bypass) rights.
        await #expect(throws: ClaudeUsageError.self) { try await background.value }
        let snapshot = try await user.value
        #expect(snapshot == makeUsageSnapshot())

        let fetches = await recorder.fetches
        #expect(fetches.map(\.interaction) == [.background, .userInitiated])
    }

    @Test
    func `user-initiated joiner is satisfied by a successful background flight`() async throws {
        let recorder = CallRecorder()
        let started = TestLatch()
        let release = TestLatch()
        let client = ClaudeUsageClient(fetchOperation: { interaction, phase in
            await recorder.recordFetch(interaction: interaction, phase: phase)
            await started.open()
            await release.wait()
            return makeUsageSnapshot()
        })

        let background = Task { try await client.fetch(interaction: .background) }
        await started.wait()
        let user = Task { try await client.fetch(interaction: .userInitiated) }
        for _ in 0..<200 {
            await Task.yield()
        }
        await release.open()

        _ = try await background.value
        _ = try await user.value
        #expect(await recorder.fetchCount == 1) // no rerun: fresh data satisfied the gesture
    }
}

// MARK: - CostScanner

struct CostScannerTests {
    @Test
    func `min-gap suppresses scans and bypass ignores it`() async {
        let recorder = CallRecorder()
        let scanner = CostScanner(minimumGap: 60, scanOperation: { _, bypassGate, historyDays in
            await recorder.recordScan(bypassGate: bypassGate, historyDays: historyDays)
            return makeCostSnapshot()
        })
        let t0 = Date(timeIntervalSince1970: 1_000_000_000)

        let first = await scanner.scan(bypassGate: false, historyDays: 30, now: t0)
        #expect(first == .scanned(makeCostSnapshot()))

        let gated = await scanner.scan(bypassGate: false, historyDays: 30, now: t0.addingTimeInterval(30))
        #expect(gated == .skipped)

        let bypassed = await scanner.scan(bypassGate: true, historyDays: 30, now: t0.addingTimeInterval(30))
        #expect(bypassed == .scanned(makeCostSnapshot()))

        // Gap measures from the last scan start (t0+30); 65s later passes.
        let later = await scanner.scan(bypassGate: false, historyDays: 30, now: t0.addingTimeInterval(95))
        #expect(later == .scanned(makeCostSnapshot()))

        #expect(await recorder.scanCount == 3)
    }

    @Test
    func `pricing refresh runs before each gate-passing scan only`() async {
        let pricingCalls = Mutex(0)
        let scanner = CostScanner(
            minimumGap: 60,
            refreshPricing: { _ in pricingCalls.withLock { $0 += 1 } },
            scanOperation: { _, _, _ in nil })
        let t0 = Date(timeIntervalSince1970: 1_000_000_000)

        _ = await scanner.scan(bypassGate: false, historyDays: 30, now: t0)
        _ = await scanner.scan(bypassGate: false, historyDays: 30, now: t0.addingTimeInterval(10)) // skipped
        _ = await scanner.scan(bypassGate: true, historyDays: 30, now: t0.addingTimeInterval(20))

        #expect(pricingCalls.withLock { $0 } == 2)
    }

    @Test
    func `concurrent scan requests join the in-flight scan`() async {
        let recorder = CallRecorder()
        let started = TestLatch()
        let release = TestLatch()
        let scanner = CostScanner(minimumGap: 60, scanOperation: { _, bypassGate, historyDays in
            await recorder.recordScan(bypassGate: bypassGate, historyDays: historyDays)
            await started.open()
            await release.wait()
            return makeCostSnapshot()
        })
        let t0 = Date(timeIntervalSince1970: 1_000_000_000)

        let first = Task { await scanner.scan(bypassGate: false, historyDays: 30, now: t0) }
        await started.wait()
        let second = Task { await scanner.scan(bypassGate: true, historyDays: 30, now: t0) }
        for _ in 0..<200 {
            await Task.yield()
        }
        await release.open()

        #expect(await first.value == .scanned(makeCostSnapshot()))
        #expect(await second.value == .scanned(makeCostSnapshot()))
        #expect(await recorder.scanCount == 1)
    }

    @Test
    func `cancelInFlight surfaces as cancelled`() async {
        let started = TestLatch()
        let scanner = CostScanner(minimumGap: 60, scanOperation: { _, _, _ throws(CancellationError) in
            await started.open()
            // Wait until cancelled.
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        })

        let scan = Task {
            await scanner.scan(bypassGate: false, historyDays: 30, now: Date(timeIntervalSince1970: 1_000_000_000))
        }
        await started.wait()
        await scanner.cancelInFlight()
        #expect(await scan.value == .cancelled)
    }
}
