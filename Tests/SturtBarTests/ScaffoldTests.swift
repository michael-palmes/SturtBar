import Foundation
import SturtBarCore
import Testing

// MARK: - RateWindow smoke tests

@Suite("RateWindow")
struct RateWindowTests {
    @Test("remainingPercent is 100 - usedPercent")
    func remainingPercent() {
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
        #expect(window.remainingPercent == 60)
    }

    @Test("remainingPercent clamps to zero when fully used")
    func remainingPercentClamped() {
        let window = RateWindow(
            usedPercent: 110,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        #expect(window.remainingPercent == 0)
    }

    @Test("backfillingResetTime returns self when resetsAt is already set")
    func backfillReturnsSelfWhenAlreadySet() {
        let resetDate = Date(timeIntervalSinceNow: 3600)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 60,
            resetsAt: resetDate,
            resetDescription: nil)
        let result = window.backfillingResetTime(from: nil as RateWindow?)
        #expect(result.resetsAt == resetDate)
    }

    @Test("backfillingResetTime carries over cached resetsAt when self has none")
    func backfillCarriesOverCachedReset() {
        let future = Date(timeIntervalSinceNow: 3600)
        let cached = RateWindow(
            usedPercent: 30,
            windowMinutes: 60,
            resetsAt: future,
            resetDescription: "in 1h")
        let fresh = RateWindow(
            usedPercent: 55,
            windowMinutes: 60,
            resetsAt: nil,
            resetDescription: nil)
        let result = fresh.backfillingResetTime(from: cached)
        #expect(result.resetsAt == future)
        #expect(result.resetDescription == "in 1h")
    }
}

// MARK: - NamedRateWindow smoke tests

@Suite("NamedRateWindow")
struct NamedRateWindowTests {
    @Test("round-trips through Codable")
    func codable() throws {
        let window = RateWindow(
            usedPercent: 75,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: "soon")
        let named = NamedRateWindow(id: "primary", title: "5-hour", window: window)
        let data = try JSONEncoder().encode(named)
        let decoded = try JSONDecoder().decode(NamedRateWindow.self, from: data)
        #expect(decoded == named)
    }
}

// MARK: - Log smoke tests

@Suite("SturtBarLog", .serialized)
struct SturtBarLogTests {
    @Test("logger does not crash on all levels")
    func loggerAllLevels() {
        let log = SturtBarLog.logger("test")
        log.trace("trace message")
        log.verbose("verbose message")
        log.debug("debug message")
        log.info("info message")
        log.warning("warning message")
        log.error("error message")
        log.critical("critical message")
    }

    @Test("logger does not crash with metadata")
    func loggerWithMetadata() {
        let log = SturtBarLog.logger("test")
        log.info("message with metadata", metadata: ["key": "value", "other": "data"])
    }

    @Test("setMinimumLevel updates the level")
    func setMinimumLevel() {
        let prior = SturtBarLog.minimumLevel()
        defer {
            SturtBarLog.setMinimumLevel(prior)
            UserDefaults.standard.removeObject(forKey: "debugLogLevel")
        }
        SturtBarLog.setMinimumLevel(.debug)
        #expect(SturtBarLog.minimumLevel() == .debug)
    }
}
