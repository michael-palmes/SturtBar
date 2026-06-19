// CodexUsageClientTests.swift — single-flight coalescing for the Codex lane + disable-cancel.
//
// Unlike ClaudeUsageClient there is no interaction upgrade (Codex fetches never prompt and have
// no user-gesture gate semantics), so joining is unconditional.

import Foundation
import Synchronization
import Testing
@testable import SturtBar
@testable import SturtBarCore

struct CodexUsageClientTests {
    @Test
    func `concurrent fetches join one in-flight run`() async throws {
        let calls = Mutex(0)
        let latch = TestLatch()
        let client = CodexUsageClient(fetchOperation: {
            calls.withLock { $0 += 1 }
            await latch.wait()
            return makeUsageSnapshot(primaryUsedPercent: 18, secondaryUsedPercent: nil, updatedAt: .init())
        })

        async let first = client.fetch()
        async let second = client.fetch()
        try await Task.sleep(for: .milliseconds(50))
        await latch.open()

        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test
    func `sequential fetches run separate operations`() async throws {
        let calls = Mutex(0)
        let client = CodexUsageClient(fetchOperation: {
            calls.withLock { $0 += 1 }
            return makeUsageSnapshot(primaryUsedPercent: 18, secondaryUsedPercent: nil, updatedAt: .init())
        })

        _ = try await client.fetch()
        _ = try await client.fetch()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test
    func `fetch errors propagate to the caller`() async {
        let client = CodexUsageClient(fetchOperation: { throw CodexUsageError.credentialsMissing })

        do {
            _ = try await client.fetch()
            Issue.record("expected credentialsMissing")
        } catch let error as CodexUsageError {
            #expect(error.indicatesCredentialsMissing)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func `cancelInFlight interrupts the running fetch`() async throws {
        let client = CodexUsageClient(fetchOperation: {
            try await Task.sleep(for: .seconds(300))
            return makeUsageSnapshot(primaryUsedPercent: 18, secondaryUsedPercent: nil, updatedAt: .init())
        })

        let fetchTask = Task {
            try await client.fetch()
        }
        try await Task.sleep(for: .milliseconds(50))
        await client.cancelInFlight()

        do {
            _ = try await fetchTask.value
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

struct ClaudeUsageClientCancelTests {
    @Test
    func `cancelInFlight interrupts the running fetch`() async throws {
        let client = ClaudeUsageClient(fetchOperation: { _, _ in
            try await Task.sleep(for: .seconds(300))
            return makeUsageSnapshot(primaryUsedPercent: 62, secondaryUsedPercent: nil, updatedAt: .init())
        })

        let fetchTask = Task {
            try await client.fetch(interaction: .background)
        }
        try await Task.sleep(for: .milliseconds(50))
        await client.cancelInFlight()

        do {
            _ = try await fetchTask.value
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
