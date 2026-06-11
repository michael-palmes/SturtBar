import Foundation

public enum Interaction: Sendable, Equatable {
    case background
    case userInitiated
}

public enum InteractionContext {
    @TaskLocal public static var current: Interaction = .background
}

public enum RefreshPhase: Sendable, Equatable {
    case regular
    case startup
}

public enum RefreshContext {
    @TaskLocal public static var current: RefreshPhase = .regular
}
