import Foundation

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description surfaced in tooltips and menu cards.
    public let resetDescription: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        nextRegenPercent: Double? = nil)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    public func backfillingResetTime(from cached: RateWindow?, now: Date = .init()) -> RateWindow {
        if self.resetsAt != nil { return self }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        let windowMinutes = if let windowMinutes = self.windowMinutes, windowMinutes > 0 {
            windowMinutes
        } else {
            cached?.windowMinutes
        }
        return RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: cachedReset,
            resetDescription: self.resetDescription ?? cached?.resetDescription,
            nextRegenPercent: self.nextRegenPercent)
    }
}

public struct NamedRateWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let window: RateWindow

    public init(id: String, title: String, window: RateWindow) {
        self.id = id
        self.title = title
        self.window = window
    }
}

/// Provider-specific spend/budget snapshot (e.g. Claude "Extra usage" monthly spend vs limit).
public struct ProviderCostSnapshot: Equatable, Codable, Sendable {
    public let used: Double
    public let limit: Double
    public let currencyCode: String
    /// Human-friendly period label (e.g. "Monthly"). Optional; some providers don't expose a period.
    public let period: String?
    /// Optional renewal/reset timestamp for the period.
    public let resetsAt: Date?
    /// Optional amount restored on the next regeneration tick for providers with rolling credit recovery.
    public let nextRegenAmount: Double?
    public let updatedAt: Date

    public init(
        used: Double,
        limit: Double,
        currencyCode: String,
        period: String? = nil,
        resetsAt: Date? = nil,
        nextRegenAmount: Double? = nil,
        updatedAt: Date)
    {
        self.used = used
        self.limit = limit
        self.currencyCode = currencyCode
        self.period = period
        self.resetsAt = resetsAt
        self.nextRegenAmount = nextRegenAmount
        self.updatedAt = updatedAt
    }
}

/// Provider-agnostic usage snapshot (produced by `ClaudeUsageService`, and by `CodexUsageService`
/// for the opt-in Codex provider). Providers fill the windows they have: Claude populates
/// `opus`/`extraRateWindows`/`providerCost`; Codex fills only `primary`/`secondary`/`loginMethod`
/// and leaves the rest nil/empty.
/// Codable so later phases can persist the last snapshot to disk.
public struct ProviderUsageSnapshot: Codable, Equatable, Sendable {
    public enum PrimaryWindowKind: String, Codable, Equatable, Sendable {
        case usage
        case spendLimit
    }

    public let primary: RateWindow
    public let primaryWindowKind: PrimaryWindowKind
    public let secondary: RateWindow?
    public let opus: RateWindow?
    public let extraRateWindows: [NamedRateWindow]
    /// Model-scoped weekly limits from the OAuth `limits` array (e.g. "Fable"), one per model.
    public let modelWeeklyWindows: [NamedRateWindow]
    public let providerCost: ProviderCostSnapshot?
    public let updatedAt: Date
    public let loginMethod: String?

    public init(
        primary: RateWindow,
        primaryWindowKind: PrimaryWindowKind = .usage,
        secondary: RateWindow?,
        opus: RateWindow?,
        extraRateWindows: [NamedRateWindow] = [],
        modelWeeklyWindows: [NamedRateWindow] = [],
        providerCost: ProviderCostSnapshot? = nil,
        updatedAt: Date,
        loginMethod: String?)
    {
        self.primary = primary
        self.primaryWindowKind = primaryWindowKind
        self.secondary = secondary
        self.opus = opus
        self.extraRateWindows = extraRateWindows
        self.modelWeeklyWindows = modelWeeklyWindows
        self.providerCost = providerCost
        self.updatedAt = updatedAt
        self.loginMethod = loginMethod
    }

    private enum CodingKeys: String, CodingKey {
        case primary
        case primaryWindowKind
        case secondary
        case opus
        case extraRateWindows
        case modelWeeklyWindows
        case providerCost
        case updatedAt
        case loginMethod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try container.decode(RateWindow.self, forKey: .primary)
        self.primaryWindowKind = try container.decode(PrimaryWindowKind.self, forKey: .primaryWindowKind)
        self.secondary = try container.decodeIfPresent(RateWindow.self, forKey: .secondary)
        self.opus = try container.decodeIfPresent(RateWindow.self, forKey: .opus)
        self.extraRateWindows = try container.decode([NamedRateWindow].self, forKey: .extraRateWindows)
        // Snapshots persisted before this field existed decode to an empty list.
        self.modelWeeklyWindows = try container
            .decodeIfPresent([NamedRateWindow].self, forKey: .modelWeeklyWindows) ?? []
        self.providerCost = try container.decodeIfPresent(ProviderCostSnapshot.self, forKey: .providerCost)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.loginMethod = try container.decodeIfPresent(String.self, forKey: .loginMethod)
    }
}
