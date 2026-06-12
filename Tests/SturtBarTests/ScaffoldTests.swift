import Foundation
import SturtBarCore
import Testing

// MARK: - RateWindow smoke tests

@Suite("RateWindow")
struct RateWindowTests {
    @Test
    func `remainingPercent is 100 - usedPercent`() {
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
        #expect(window.remainingPercent == 60)
    }

    @Test
    func `remainingPercent clamps to zero when fully used`() {
        let window = RateWindow(
            usedPercent: 110,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        #expect(window.remainingPercent == 0)
    }

    @Test
    func `backfillingResetTime returns self when resetsAt is already set`() {
        let resetDate = Date(timeIntervalSinceNow: 3600)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 60,
            resetsAt: resetDate,
            resetDescription: nil)
        let result = window.backfillingResetTime(from: nil as RateWindow?)
        #expect(result.resetsAt == resetDate)
    }

    @Test
    func `backfillingResetTime carries over cached resetsAt when self has none`() {
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
    @Test
    func `round-trips through Codable`() throws {
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
    @Test
    func `logger does not crash on all levels`() {
        let log = SturtBarLog.logger("test")
        log.trace("trace message")
        log.verbose("verbose message")
        log.debug("debug message")
        log.info("info message")
        log.warning("warning message")
        log.error("error message")
        log.critical("critical message")
    }

    @Test
    func `logger does not crash with metadata`() {
        let log = SturtBarLog.logger("test")
        log.info("message with metadata", metadata: ["key": "value", "other": "data"])
    }

    @Test
    func `setMinimumLevel updates the level`() {
        let prior = SturtBarLog.minimumLevel()
        defer {
            SturtBarLog.setMinimumLevel(prior)
            UserDefaults.standard.removeObject(forKey: "debugLogLevel")
        }
        SturtBarLog.setMinimumLevel(.debug)
        #expect(SturtBarLog.minimumLevel() == .debug)
    }
}
