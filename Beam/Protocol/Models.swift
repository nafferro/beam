import Foundation

/// Constant-light setting (one of the 3 "static" slots on the lamp).
struct StaticVariant: Codable, Equatable, Hashable {
    var narrow: Int      // narrow beam power, 0...1000
    var wide: Int        // wide beam power, 0...1000
    var autonomy: Int    // guaranteed run time, minutes
    var behavior: Int    // 1...6

    static let empty = StaticVariant(narrow: 0, wide: 0, autonomy: 0, behavior: 0)
    var isEmpty: Bool { autonomy == 0 && narrow == 0 && wide == 0 }
}

/// Reactive-light setting (one of the 3 "dynamic" slots on the lamp).
struct DynamicVariant: Codable, Equatable, Hashable {
    var behavior: Int
    var narrowStartDistance: Int
    var narrowMax: Int
    var wideMax: Int
    var wideMaxWhenNarrowMax: Int
    var readingThreshold: Int
    var autonomy: Int    // minutes

    static let empty = DynamicVariant(behavior: 0, narrowStartDistance: 0, narrowMax: 0, wideMax: 0,
                                      wideMaxWhenNarrowMax: 0, readingThreshold: 0, autonomy: 0)
    var isEmpty: Bool { autonomy == 0 && narrowMax == 0 && wideMax == 0 }
}

/// Which light the lamp is producing right now (parameter 0x03).
enum LampMode: Equatable {
    case off
    case reactive(variant: Int)
    case constant(variant: Int)
    case red(variant: Int)
    case unknown(UInt8)

    init(byte: UInt8) {
        let hi = byte >> 4, lo = byte & 0x0F
        switch (hi, lo) {
        case (0, 0): self = .off
        case (0, 1...9): self = .reactive(variant: Int(lo))
        case (1, 0...9): self = .constant(variant: Int(lo))
        case (1, 0xB): self = .red(variant: 1)
        case (1, 0xC): self = .red(variant: 2)
        default: self = .unknown(byte)
        }
    }

    /// Variant number as the original app computes it (used in the red-mode frame).
    var variantNumber: Int {
        switch self {
        case .reactive(let n), .constant(let n), .red(let n): return n
        default: return 0
        }
    }
}

enum RedMode: UInt8, CaseIterable, Identifiable {
    case off = 0x00, constant = 0x01, blink = 0x03
    var id: UInt8 { rawValue }
}

struct GeneralInfo: Equatable {
    var mode: LampMode
    var redMode: UInt8?
}

struct BatteryInfo: Equatable {
    var fuel: UInt32
    var fuelMax: UInt32
    var totalCharges: UInt32
    var ageing: Int
    var chargeState: UInt8

    /// 0...1, nil if the lamp reported no maximum.
    var level: Double? {
        guard fuelMax > 0 else { return nil }
        return min(1, Double(fuel) / Double(fuelMax))
    }
    var isReliable: Bool { ageing <= 300 }
}

struct SoftwareInfo: Equatable {
    var fid: String
    var firmware: String
    var bootloader: String
}

struct DeviceInfo: Equatable {
    var serialNumber: String
    var productType: UInt8
}

/// A whole profile: name + 3 static + 3 dynamic slots.
struct LampProfile: Codable, Equatable, Identifiable {
    var id: String
    var lampName: String              // name written to the lamp
    var displayName: String
    var staticVariants: [StaticVariant]
    var dynamicVariants: [DynamicVariant]
    var isCustom: Bool = false

    enum CodingKeys: String, CodingKey { case id, lampName, displayName, staticVariants, dynamicVariants }
}
