// CodexUsageClient.swift — single-flight point for Codex usage fetches.
//
// Same slot mechanics as ClaudeUsageClient, minus the join-or-upgrade loop: Codex fetches never
// prompt (no keychain) and have no user-gesture gate semantics, so joiners simply share the
// in-flight result. `cancelInFlight` exists for the provider-disable path (decision 6): turning
// the provider off must abort any network call already in the air.

import Foundation
import SturtBarCore

actor CodexUsageClient {
    typealias FetchOperation = @Sendable () async throws -> ProviderUsageSnapshot

    private let fetchOperation: FetchOperation
    private var inFlight: Task<ProviderUsageSnapshot, any Error>?

    /// Production entry: wraps a `CodexUsageService`.
    init(service: CodexUsageService) {
        self.fetchOperation = { try await service.fetchUsage() }
    }

    /// Test seam: injects the fetch implementation directly.
    init(fetchOperation: @escaping FetchOperation) {
        self.fetchOperation = fetchOperation
    }

    /// Fetches a usage snapshot, coalescing concurrent callers onto one in-flight fetch.
    func fetch() async throws -> ProviderUsageSnapshot {
        if let current = self.inFlight {
            // Awaiting .value would propagate this caller's cancellation into the shared task;
            // `.result` keeps the flight alive for other joiners (same rationale as Claude's).
            return try await current.result.get()
        }

        let operation = self.fetchOperation
        // Self-clearing slot: the defer runs inside the task closure (actor-isolated), so the
        // slot is empty before the result is observable to any joiner.
        let task = Task {
            defer { self.inFlight = nil }
            return try await operation()
        }
        self.inFlight = task
        return try await task.value
    }

    /// Aborts the in-flight fetch, if any (provider-disable path). The slot self-clears when the
    /// cancelled task finishes.
    func cancelInFlight() {
        self.inFlight?.cancel()
    }
}
