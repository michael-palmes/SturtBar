import Foundation
import SturtBarCore

/// Keeps the menu bar icon where the user put it. macOS saves the position per autosave name,
/// clears it when an item is removed while the app runs, and restores bad saved values off screen.
enum StatusItemPlacement {
    static let autosaveName = "sturtbar-main"
    /// The name macOS gave the unnamed item in 1.3.1 and earlier.
    private static let legacyAutosaveName = "Item-0"
    private static let offscreenPadding: Double = 512
    private static let log = SturtBarLog.logger("status-item")

    static func positionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    static func shouldDiscard(_ value: Any, maxScreenWidth: Double?) -> Bool {
        guard let position = (value as? NSNumber)?.doubleValue, position.isFinite, position > 0 else { return true }
        return maxScreenWidth.map { position > $0 + self.offscreenPadding } ?? false
    }

    /// Runs before the item is named: carries the legacy position over once, then drops a bad value.
    static func prepare(defaults: UserDefaults, maxScreenWidth: Double?) {
        let key = self.positionKey(self.autosaveName)
        let legacyKey = self.positionKey(self.legacyAutosaveName)
        if defaults.object(forKey: key) == nil, let legacy = defaults.object(forKey: legacyKey) {
            defaults.set(legacy, forKey: key)
            defaults.removeObject(forKey: legacyKey)
        }
        if let saved = defaults.object(forKey: key), self.shouldDiscard(saved, maxScreenWidth: maxScreenWidth) {
            defaults.removeObject(forKey: key)
            self.log.info("Discarded an invalid saved menu bar position")
        }
    }

    /// Writes the saved position back if `body` (removing the item) made macOS forget it.
    @discardableResult
    static func preservingPosition<T>(defaults: UserDefaults, _ body: () -> T) -> T {
        let key = self.positionKey(self.autosaveName)
        let saved = defaults.object(forKey: key)
        let result = body()
        if let saved, defaults.object(forKey: key) == nil {
            defaults.set(saved, forKey: key)
        }
        return result
    }
}
