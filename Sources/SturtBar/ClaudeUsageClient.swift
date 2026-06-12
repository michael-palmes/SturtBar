// ClaudeUsageClient.swift — THE single-flight point for Claude usage fetches.
//
// Integration contract (Phase 3a):
//   - Never call OAuth-store sync entry points from MainActor: the credentials store can block on
//     keychain prompts / /usr/bin/security spawns. Everything goes through this actor, so at most
//     one fetch is in flight process-wide and all of them run off the main actor.
//   - `ClaudeUsageService.fetchUsage(interaction:phase:)` is the only entry point; the service
//     binds the InteractionContext/RefreshContext TaskLocals internally from its parameters, so
//     spawning the fetch in an unstructured Task here cannot drop them.
//
// Placement: app target (not SturtBarCore). Single-flight + upgrade is process-lifecycle policy
// for THIS app's runtime; SturtBarCore stays a stateless service library (its docs already point
// here: "designed to be wrapped in an actor (`ClaudeUsageClient`)").
//
// Join-or-upgrade policy (await-then-rerun):
//   A `.userInitiated` fetch arriving while a `.background` fetch is in flight JOINS the flight
//   first. If the joined flight SUCCEEDS, its snapshot satisfies the user gesture (the data is
//   milliseconds old — re-fetching with gate bypass would buy nothing). If it FAILS — which
//   includes "was gated" outcomes such as keychain-prompt cooldowns, because gated loads surface
//   as thrown credential errors — the gesture's gate-bypass semantics must not be lost, so the
//   client reruns once as `.userInitiated` (which may prompt / clear cooldowns). The rerun loops
//   through the same join logic in case yet another flight started meanwhile.
//   Chosen over in-place upgrade because the in-flight task's TaskLocal interaction is immutable
//   once the service binds it; "upgrading" would really mean cancel+restart, which wastes the
//   in-flight network call and complicates cancellation semantics.

import Foundation
import SturtBarCore

actor ClaudeUsageClient {
    typealias FetchOperation = @Sendable (
        _ interaction: Interaction,
        _ phase: RefreshPhase) async throws -> ProviderUsageSnapshot

    private struct InFlight {
        let task: Task<ProviderUsageSnapshot, any Error>
        let interaction: Interaction
    }

    private let fetchOperation: FetchOperation
    private var inFlight: InFlight?
    private static let log = SturtBarLog.logger("usage-client")

    /// Production entry: wraps a `ClaudeUsageService`.
    init(service: ClaudeUsageService) {
        self.fetchOperation = { interaction, phase in
            try await service.fetchUsage(interaction: interaction, phase: phase)
        }
    }

    /// Test seam: injects the fetch implementation directly.
    init(fetchOperation: @escaping FetchOperation) {
        self.fetchOperation = fetchOperation
    }

    /// Fetches a usage snapshot, coalescing concurrent callers onto one in-flight fetch.
    /// See the join-or-upgrade policy in the header comment.
    func fetch(
        interaction: Interaction,
        phase: RefreshPhase = .regular) async throws -> ProviderUsageSnapshot
    {
        while let current = self.inFlight {
            let joinedInteraction = current.interaction
            // Awaiting .value does not propagate this caller's cancellation into the shared task;
            // other joiners keep their flight.
            let result = await current.task.result
            switch result {
            case let .success(snapshot):
                return snapshot
            case let .failure(error):
                if interaction == .userInitiated, joinedInteraction == .background {
                    // Upgrade: the background flight failed (possibly gated); rerun with
                    // user-initiated rights. Loop — another flight may have started while we waited.
                    Self.log.info("Joined background fetch failed; rerunning as user-initiated")
                    continue
                }
                throw error
            }
        }
        return try await self.run(interaction: interaction, phase: phase)
    }

    /// Aborts the in-flight fetch, if any (provider-disable path). The slot self-clears when the
    /// cancelled task finishes.
    func cancelInFlight() {
        self.inFlight?.task.cancel()
    }

    private func run(
        interaction: Interaction,
        phase: RefreshPhase) async throws -> ProviderUsageSnapshot
    {
        let operation = self.fetchOperation
        // The task clears `inFlight` from INSIDE its closure (actor-isolated, runs as part of the
        // task finishing) so the slot is guaranteed empty before the result is observable to any
        // joiner. Clearing from this method instead would race with an upgrade-looping joiner that
        // re-reads `inFlight`, sees the already-completed flight, and re-joins it forever.
        let task = Task {
            defer { self.inFlight = nil }
            return try await operation(interaction, phase)
        }
        self.inFlight = InFlight(task: task, interaction: interaction)
        return try await task.value
    }
}
