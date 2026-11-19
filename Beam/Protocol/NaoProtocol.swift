import CoreBluetooth
import Foundation

/// GATT layout of the lamp. All three services are custom.
enum NaoGATT {
    static let securityService = CBUUID(string: "13172bf6-8ab6-11e4-b116-123b93f75cba")
    static let securityWrite   = CBUUID(string: "131731d2-8ab6-11e4-b116-123b93f75cba")
    static let securityNotify  = CBUUID(string: "1317304c-8ab6-11e4-b116-123b93f75cba")

    static let lightService    = CBUUID(string: "09b6b382-7b08-11e4-b116-123b93f75cba")
    static let lightWrite      = CBUUID(string: "09b6b5da-7b08-11e4-b116-123b93f75cba")
    static let lightNotify     = CBUUID(string: "09b6b72e-7b08-11e4-b116-123b93f75cba")

    static let batteryService  = CBUUID(string: "68866e2a-7b08-11e4-b116-123b93f75cba")
    static let batteryWrite    = CBUUID(string: "68867230-7b08-11e4-b116-123b93f75cba")
    static let batteryNotify   = CBUUID(string: "6886738e-7b08-11e4-b116-123b93f75cba")

    static let services = [securityService, lightService, batteryService]
    /// Order in which notifications are switched on.
    static let notifyOrder = [securityNotify, lightNotify, batteryNotify]

    /// Petzl Bluetooth company id as it appears in the advertisement (0x0296, little-endian).
    static let manufacturerPrefix: [UInt8] = [0x96, 0x02]
    static let naoFIDs: Set<String> = ["1A0D", "1A2D", "0D1A", "1A2C"]
}

/// Which characteristic a frame is written to.
enum Channel { case security, light, battery }

/// One outgoing frame and how to recognise its reply.
struct Command: Equatable {
    var channel: Channel
    var bytes: [UInt8]
    /// First byte of the notification that acknowledges this command.
    var ackByte: UInt8
    var label: String

    init(_ channel: Channel, _ bytes: [UInt8], ack: UInt8? = nil, label: String) {
        self.channel = channel
        self.bytes = bytes
        self.ackByte = ack ?? bytes[0]
        self.label = label
    }
}

/// Builds the frames the lamp understands. NAO+ only (big-endian variant fields).
enum NaoCommands {
    static let get: UInt8 = 0x73
    static let set: UInt8 = 0x74

    enum Param {
        static let lampName: UInt8 = 0x00
        static let generalInfo: UInt8 = 0x03
        static let softwareInfo: UInt8 = 0x08
        static let deviceInfo: UInt8 = 0x10
        static let profileName: [UInt8] = [0x20, 0x21, 0x22]
        static let dynamicVariant: [UInt8] = [0x23, 0x24, 0x25]
        static let staticVariant: [UInt8] = [0x26, 0x27, 0x28]
        static let batteryInfo: UInt8 = 0x03
        static let batterySoftware: UInt8 = 0x08
    }

    /// ASCII "Petzl_38920_", same for every lamp.
    static let securityKey = Command(.security, Array("Petzl_38920_".utf8), ack: 0xAA, label: "key")

    static func read(_ param: UInt8, label: String) -> Command {
        Command(.light, [get, param], label: label)
    }

    static let readGeneralInfo = read(Param.generalInfo, label: "mode")
    static let readLampName = read(Param.lampName, label: "name")
    static let readSoftware = read(Param.softwareInfo, label: "software")
    static let readDevice = read(Param.deviceInfo, label: "device")
    static let readBattery = Command(.battery, [0x20, Param.batteryInfo], label: "battery")
    static let readBatterySoftware = Command(.battery, [0x20, Param.batterySoftware], label: "battery software")

    static var readProfile: [Command] {
        Param.profileName.enumerated().map { read($1, label: "profile name \($0 + 1)") }
        + Param.dynamicVariant.enumerated().map { read($1, label: "reactive \($0 + 1)") }
        + Param.staticVariant.enumerated().map { read($1, label: "constant \($0 + 1)") }
    }

    static let sync = Command(.light, [0x65, 0x01], label: "sync")
    static let startLive = Command(.light, [0x71, 0x01], label: "live on")
    static let stopLive = Command(.light, [0x71, 0x00], label: "live off")
    static let stopSOS = Command(.light, [0x76, 0x00], ack: 0xF6, label: "stop SOS")

    static func sos(_ text: String) -> Command? {
        guard let payload = Morse.payload(for: text) else { return nil }
        return Command(.light, [0x75] + payload, ack: 0xF5, label: "SOS")
    }

    /// Red light (NAO+). Goes to the battery characteristic, like the original app.
    static func setRedMode(_ mode: RedMode, currentVariant: Int) -> Command {
        let n = max(0, min(99, currentVariant))
        // The variant number is written as two *decimal* digits read as hex ("%02d").
        let nn = UInt8((n / 10) << 4 | (n % 10))
        var data: [UInt8] = [nn, mode.rawValue]
        data += Array(repeating: 0, count: 10 - data.count)
        return Command(.battery, [set, Param.generalInfo] + data, label: "red light")
    }

    static func writeStatic(_ v: StaticVariant?, slot: Int) -> Command {
        var data = [UInt8](repeating: 0, count: 18)
        if let v, !v.isEmpty {
            data.replaceSubrange(0..<2, with: be16(v.narrow))
            data.replaceSubrange(2..<4, with: be16(v.wide))
            data.replaceSubrange(4..<6, with: be16(v.autonomy))
            data[6] = UInt8(clamping: v.behavior)
        }
        return Command(.light, [set, Param.staticVariant[slot - 1]] + data, label: "write constant \(slot)")
    }

    static func writeDynamic(_ v: DynamicVariant?, slot: Int) -> Command {
        var data = [UInt8](repeating: 0, count: 18)
        if let v, !v.isEmpty {
            data[0] = UInt8(clamping: v.behavior)
            data[1] = UInt8(clamping: v.narrowStartDistance)
            data.replaceSubrange(2..<4, with: be16(v.narrowMax))
            data.replaceSubrange(4..<6, with: be16(v.wideMax))
            data.replaceSubrange(6..<8, with: be16(v.wideMaxWhenNarrowMax))
            data[8] = UInt8(clamping: v.readingThreshold)
            data.replaceSubrange(10..<12, with: be16(v.autonomy))
        }
        return Command(.light, [set, Param.dynamicVariant[slot - 1]] + data, label: "write reactive \(slot)")
    }

    /// Profile name: UTF-16BE with a FE FF byte-order mark, padded to 52 bytes,
    /// split into 18 + 18 + 16 bytes; the last frame ends with 0x00 + custom flag.
    static func writeProfileName(_ name: String, custom: Bool) -> [Command] {
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in name.utf16 { bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        bytes = Array(bytes.prefix(52))
        bytes += Array(repeating: 0, count: 52 - bytes.count)
        let parts = [Array(bytes[0..<18]), Array(bytes[18..<36]), Array(bytes[36..<52]) + [0x00, custom ? 1 : 0]]
        return parts.enumerated().map {
            Command(.light, [set, Param.profileName[$0.offset]] + $0.element, label: "write name \($0.offset + 1)")
        }
    }

    /// Everything needed to put a whole profile on the lamp, then read it back.
    static func writeProfile(_ p: LampProfile) -> [Command] {
        var out = writeProfileName(p.lampName, custom: p.isCustom)
        for slot in 1...3 { out.append(writeStatic(p.staticVariants[safe: slot - 1], slot: slot)) }
        for slot in 1...3 { out.append(writeDynamic(p.dynamicVariants[safe: slot - 1], slot: slot)) }
        out.append(sync)
        return out + readProfile
    }

    static func be16(_ v: Int) -> [UInt8] {
        let x = UInt16(clamping: v)
        return [UInt8(x >> 8), UInt8(x & 0xFF)]
    }
}

/// Everything the lamp can tell us, decoded from one notification.
enum LampEvent: Equatable {
    case authResult(firstPairing: Bool)
    case lampName(String)
    case general(GeneralInfo)
    case software(SoftwareInfo)
    case device(DeviceInfo)
    case battery(BatteryInfo)
    case batterySoftware(SoftwareInfo)
    case profileNamePart(index: Int, bytes: [UInt8])
    case staticVariant(slot: Int, StaticVariant)
    case dynamicVariant(slot: Int, DynamicVariant)
    case ack(UInt8)
}

enum NaoParser {
    static func parse(_ d: [UInt8], channel: Channel) -> LampEvent? {
        guard let first = d.first else { return nil }
        if channel == .security, d.count == 1 {
            if first == 0xAA { return .authResult(firstPairing: false) }
            if first == 0xA5 { return .authResult(firstPairing: true) }
        }
        guard d.count >= 2 else { return .ack(first) }
        let key = (first, d[1])
        let body = Array(d.dropFirst(2))

        switch key {
        case (0x73, NaoCommands.Param.lampName):
            let s = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            return .lampName(s)
        case (0x73, NaoCommands.Param.generalInfo) where body.count >= 1:
            return .general(GeneralInfo(mode: LampMode(byte: body[0]), redMode: body.count >= 2 ? body[1] : nil))
        case (0x73, NaoCommands.Param.softwareInfo) where body.count >= 6:
            return .software(SoftwareInfo(fid: hex(body[0...1]),
                                          firmware: "\(body[2]).\(body[3])",
                                          bootloader: "\(body[4]).\(body[5])"))
        case (0x73, NaoCommands.Param.deviceInfo) where body.count >= 5:
            return .device(DeviceInfo(serialNumber: hex(body[0...3]), productType: body[4]))
        case (0x73, let p) where NaoCommands.Param.profileName.contains(p):
            return .profileNamePart(index: Int(p - 0x20), bytes: body)
        case (0x73, let p) where NaoCommands.Param.staticVariant.contains(p) && body.count >= 7:
            return .staticVariant(slot: Int(p - 0x25), StaticVariant(
                narrow: be(body, 0), wide: be(body, 2), autonomy: be(body, 4), behavior: Int(body[6])))
        case (0x73, let p) where NaoCommands.Param.dynamicVariant.contains(p) && body.count >= 12:
            return .dynamicVariant(slot: Int(p - 0x22), DynamicVariant(
                behavior: Int(body[0]), narrowStartDistance: Int(body[1]),
                narrowMax: be(body, 2), wideMax: be(body, 4), wideMaxWhenNarrowMax: be(body, 6),
                readingThreshold: Int(body[8]), autonomy: be(body, 10)))
        case (0x20, NaoCommands.Param.batteryInfo) where body.count >= 14:
            // NAO+: little-endian counters (Reactik+ uses big-endian).
            return .battery(BatteryInfo(fuel: le32(body, 0), fuelMax: le32(body, 4),
                                        totalCharges: le32(body, 8), ageing: Int(body[12]),
                                        chargeState: body[13]))
        case (0x20, NaoCommands.Param.batterySoftware) where body.count >= 6:
            return .batterySoftware(SoftwareInfo(fid: hex([body[1], body[0]]),
                                                 firmware: "\(body[2]).\(body[3])",
                                                 bootloader: "\(body[4]).\(body[5])"))
        default:
            return .ack(first)
        }
    }

    /// Joins the three profile-name fragments (18 + 18 + 16 bytes of text).
    static func profileName(from parts: [[UInt8]]) -> (name: String, custom: Bool)? {
        guard parts.count == 3, parts.allSatisfy({ $0.count >= 18 }) else { return nil }
        let raw = parts[0].prefix(18) + parts[1].prefix(18) + parts[2].prefix(16)
        let custom = parts[2][17] == 1
        return (decodeName(Array(raw)), custom)
    }

    static func decodeName(_ raw: [UInt8]) -> String {
        var b = raw
        while b.last == 0 { b.removeLast() }
        var s: String
        if b.starts(with: [0xFE, 0xFF]) {
            b.removeFirst(2)
            if b.count % 2 == 1 { b.append(0) }
            s = String(data: Data(b), encoding: .utf16BigEndian) ?? ""
        } else if b.count >= 2, b[0] == 0 {
            // UTF-16BE without a byte-order mark (ASCII text starts with 0x00).
            if b.count % 2 == 1 { b.append(0) }
            s = String(data: Data(b), encoding: .utf16BigEndian) ?? ""
        } else {
            s = String(decoding: b, as: UTF8.self)
        }
        return s.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func be(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func hex<C: Collection>(_ b: C) -> String where C.Element == UInt8 {
        b.map { String(format: "%02X", $0) }.joined()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
