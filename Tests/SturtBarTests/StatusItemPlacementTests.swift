import Foundation
import Testing
@testable import SturtBar

struct StatusItemPlacementTests {
    private static func defaults(_ name: String) -> UserDefaults {
        let suite = "sturtbar-placement-\(name)-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private static let key = StatusItemPlacement.positionKey(StatusItemPlacement.autosaveName)
    private static let legacyKey = StatusItemPlacement.positionKey("Item-0")

    @Test
    func `invalid saved positions are discarded`() {
        #expect(StatusItemPlacement.shouldDiscard(Double.nan, maxScreenWidth: 1512))
        #expect(StatusItemPlacement.shouldDiscard(Double.infinity, maxScreenWidth: 1512))
        #expect(StatusItemPlacement.shouldDiscard(0.0, maxScreenWidth: 1512))
        #expect(StatusItemPlacement.shouldDiscard(-40.0, maxScreenWidth: 1512))
        #expect(StatusItemPlacement.shouldDiscard("left", maxScreenWidth: 1512))
        #expect(StatusItemPlacement.shouldDiscard(99999.0, maxScreenWidth: 1512))
        #expect(!StatusItemPlacement.shouldDiscard(845.0, maxScreenWidth: 1512))
        #expect(!StatusItemPlacement.shouldDiscard(99999.0, maxScreenWidth: nil))
    }

    @Test
    func `the legacy position carries over once`() {
        let defaults = Self.defaults("migrate")
        defaults.set(612.0, forKey: Self.legacyKey)

        StatusItemPlacement.prepare(defaults: defaults, maxScreenWidth: 1512)

        #expect(defaults.double(forKey: Self.key) == 612)
        #expect(defaults.object(forKey: Self.legacyKey) == nil)
    }

    @Test
    func `an existing position is not overwritten by the legacy one`() {
        let defaults = Self.defaults("keep")
        defaults.set(300.0, forKey: Self.key)
        defaults.set(612.0, forKey: Self.legacyKey)

        StatusItemPlacement.prepare(defaults: defaults, maxScreenWidth: 1512)

        #expect(defaults.double(forKey: Self.key) == 300)
    }

    @Test
    func `a bad saved position is removed before the item is named`() {
        let defaults = Self.defaults("bad")
        defaults.set(99999.0, forKey: Self.key)

        StatusItemPlacement.prepare(defaults: defaults, maxScreenWidth: 1512)

        #expect(defaults.object(forKey: Self.key) == nil)
    }

    @Test
    func `the saved position survives a removal that clears it`() {
        let defaults = Self.defaults("preserve")
        defaults.set(845.0, forKey: Self.key)

        StatusItemPlacement.preservingPosition(defaults: defaults) {
            defaults.removeObject(forKey: Self.key)
        }

        #expect(defaults.double(forKey: Self.key) == 845)
    }

    @Test
    func `no position is invented when none was saved`() {
        let defaults = Self.defaults("missing")

        StatusItemPlacement.preservingPosition(defaults: defaults) {}

        #expect(defaults.object(forKey: Self.key) == nil)
    }
}
