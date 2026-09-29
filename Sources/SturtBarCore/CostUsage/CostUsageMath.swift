import Foundation

/// Overflow-safe arithmetic for token tallies read from local logs, which may hold any number.
enum CostUsageMath {
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? Int.max : Int.min
    }

    static func sum(_ values: Int...) -> Int {
        values.reduce(0, self.add)
    }

    static func tokenCount(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double > 0 else { return 0 }
        guard double < Double(Int.max) else { return Int.max }
        return max(0, number.intValue)
    }

    static func nanos(fromUSD value: Double) -> Int? {
        let scaled = (value * 1_000_000_000).rounded()
        guard scaled.isFinite, scaled >= 0, scaled < Double(Int.max) else { return nil }
        return Int(scaled)
    }
}

extension Int {
    mutating func addSaturating(_ other: Int) {
        self = CostUsageMath.add(self, other)
    }
}
