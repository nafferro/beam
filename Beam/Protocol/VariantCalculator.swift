import Foundation

/// Turns "behaviour + run time" into beam powers for the NAO+,
/// using the same formulas as the original Android app.
enum VariantCalculator {
    /// Allowed run time (minutes) per behaviour, from the original app.
    static func autonomyRange(behavior: Int, isStatic: Bool) -> ClosedRange<Int> {
        let staticRanges = [1: 80...915, 2: 80...1110, 3: 75...915, 4: 85...960, 5: 110...1710, 6: 80...360]
        let dynamicRanges = [1: 390...1320, 2: 430...1320, 3: 450...1320, 4: 570...1200, 5: 700...1320, 6: 150...360]
        let table = isStatic ? staticRanges : dynamicRanges
        return table[behavior] ?? table[1]!
    }

    /// Usable battery capacity (mAh) for a given run time.
    /// `ageing` comes from the battery frame. The original formula goes negative for
    /// small `ageing` values, so we fall back to a new battery (ageing 100) when that happens.
    static func capacity(ageing: Int?, autonomy: Int) -> (value: Double, estimated: Bool) {
        func formula(_ a: Int) -> Double {
            2496.0 - Double(100 - a) * 2600.0 / 100.0 - 140.0 - (Double(autonomy) / 60.0) * 45.0
        }
        if let ageing {
            let c = formula(ageing)
            if c > 0 { return (c, false) }
        }
        return (max(1, formula(100)), true)
    }

    static func staticFactor(_ behavior: Int) -> Double {
        switch behavior {
        case 2: return 0.8
        case 3: return 2.0
        case 4: return 3.333
        case 5: return 0
        case 6: return 0.7
        default: return 0.5
        }
    }

    static func dynamicFactor(_ behavior: Int) -> Double {
        switch behavior {
        case 2: return 0.8
        case 3: return 1.4
        case 4: return 3.333
        case 5: return 0.7
        default: return 1.0
        }
    }

    static func staticVariant(behavior: Int, autonomy: Int, ageing: Int?) -> StaticVariant {
        let cap = capacity(ageing: ageing, autonomy: autonomy).value
        let f = staticFactor(behavior)
        let k = cap / Double(max(1, autonomy)) * 60.0
        let power = clamp((k * 1000.0 / ((1 + f) * 1250.0)).rounded())
        if behavior == 5 {
            return StaticVariant(narrow: 0, wide: power, autonomy: autonomy, behavior: behavior)
        }
        return StaticVariant(narrow: power, wide: clamp((f * Double(power)).rounded()),
                             autonomy: autonomy, behavior: behavior)
    }

    static func dynamicVariant(behavior: Int, autonomy: Int, ageing: Int?) -> DynamicVariant {
        let cap = capacity(ageing: ageing, autonomy: autonomy).value
        let f = dynamicFactor(behavior)
        let d = cap / (Double(max(1, autonomy)) * 60.0) * 7.875
        let power = clamp((d * 1_000_000.0 / ((1 + f) * 1250.0)).rounded())
        var v = DynamicVariant(behavior: behavior, narrowStartDistance: behavior <= 2 ? 2 : 1,
                               narrowMax: 0, wideMax: 0, wideMaxWhenNarrowMax: 0,
                               readingThreshold: 20, autonomy: autonomy)
        if behavior == 5 {
            v.wideMax = power
        } else {
            v.narrowMax = power
            v.wideMax = clamp((Double(power) * f).rounded())
        }
        return v
    }

    private static func clamp(_ x: Double) -> Int { Int(min(1000, max(0, x))) }
}
