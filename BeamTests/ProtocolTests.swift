import XCTest
@testable import Beam

final class ProtocolTests: XCTestCase {

    func testSecurityKeyIsPetzlAscii() {
        XCTAssertEqual(NaoCommands.securityKey.bytes,
                       [0x50, 0x65, 0x74, 0x7A, 0x6C, 0x5F, 0x33, 0x38, 0x39, 0x32, 0x30, 0x5F])
        XCTAssertEqual(NaoCommands.securityKey.ackByte, 0xAA)
    }

    func testReadProfileOrderMatchesOriginalCodes() {
        let heads = NaoCommands.readProfile.map { $0.bytes }
        XCTAssertEqual(heads, [[0x73, 0x20], [0x73, 0x21], [0x73, 0x22],
                               [0x73, 0x23], [0x73, 0x24], [0x73, 0x25],
                               [0x73, 0x26], [0x73, 0x27], [0x73, 0x28]])
    }

    func testStaticVariantFrameIsBigEndianAnd20Bytes() {
        let cmd = NaoCommands.writeStatic(StaticVariant(narrow: 197, wide: 394, autonomy: 180, behavior: 3), slot: 3)
        XCTAssertEqual(cmd.bytes.count, 20)
        XCTAssertEqual(Array(cmd.bytes.prefix(9)), [0x74, 0x28, 0x00, 0xC5, 0x01, 0x8A, 0x00, 0xB4, 0x03])
        XCTAssertTrue(cmd.bytes.dropFirst(9).allSatisfy { $0 == 0 })
    }

    func testEmptyVariantIsAllZeros() {
        let cmd = NaoCommands.writeDynamic(nil, slot: 2)
        XCTAssertEqual(cmd.bytes, [0x74, 0x24] + Array(repeating: 0, count: 18))
    }

    func testDynamicVariantRoundTrip() {
        let v = DynamicVariant(behavior: 3, narrowStartDistance: 1, narrowMax: 706, wideMax: 988,
                               wideMaxWhenNarrowMax: 0, readingThreshold: 30, autonomy: 450)
        let frame = NaoCommands.writeDynamic(v, slot: 3).bytes
        // Lamp answers a GET with the same layout, opcode 0x73.
        let reply = [UInt8(0x73)] + frame.dropFirst()
        XCTAssertEqual(NaoParser.parse(reply, channel: .light), .dynamicVariant(slot: 3, v))
    }

    func testStaticVariantRoundTrip() {
        let v = StaticVariant(narrow: 40, wide: 80, autonomy: 720, behavior: 3)
        let reply = [UInt8(0x73)] + NaoCommands.writeStatic(v, slot: 1).bytes.dropFirst()
        XCTAssertEqual(NaoParser.parse(reply, channel: .light), .staticVariant(slot: 1, v))
    }

    func testProfileNameRoundTrip() {
        let cmds = NaoCommands.writeProfileName("Trail-running", custom: false)
        XCTAssertEqual(cmds.count, 3)
        XCTAssertEqual(cmds.map { $0.bytes.count }, [20, 20, 20])
        XCTAssertEqual(Array(cmds[0].bytes.prefix(6)), [0x74, 0x20, 0xFE, 0xFF, 0x00, 0x54])
        let parts = cmds.map { Array($0.bytes.dropFirst(2)) }
        let decoded = NaoParser.profileName(from: parts)
        XCTAssertEqual(decoded?.name, "Trail-running")
        XCTAssertEqual(decoded?.custom, false)
    }

    func testCustomFlagAndAccents() {
        let parts = NaoCommands.writeProfileName("My Ultra Trilho", custom: true).map { Array($0.bytes.dropFirst(2)) }
        XCTAssertEqual(NaoParser.profileName(from: parts)?.name, "My Ultra Trilho")
        XCTAssertEqual(NaoParser.profileName(from: parts)?.custom, true)
    }

    func testLampModeDecoding() {
        XCTAssertEqual(LampMode(byte: 0x00), .off)
        XCTAssertEqual(LampMode(byte: 0x02), .reactive(variant: 2))
        XCTAssertEqual(LampMode(byte: 0x13), .constant(variant: 3))
        XCTAssertEqual(LampMode(byte: 0x1B), .red(variant: 1))
        XCTAssertEqual(LampMode(byte: 0x1C), .red(variant: 2))
    }

    func testRedModeFrame() {
        let cmd = NaoCommands.setRedMode(.blink, currentVariant: 2)
        XCTAssertEqual(cmd.channel, .battery)
        XCTAssertEqual(cmd.bytes, [0x74, 0x03, 0x02, 0x03, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testBatteryParsingLittleEndian() {
        let reply: [UInt8] = [0x20, 0x03, 0x10, 0x27, 0, 0, 0x20, 0x4E, 0, 0, 0x05, 0, 0, 0, 0x5A, 0x01]
        guard case .battery(let b)? = NaoParser.parse(reply, channel: .battery) else { return XCTFail() }
        XCTAssertEqual(b.fuel, 10_000)
        XCTAssertEqual(b.fuelMax, 20_000)
        XCTAssertEqual(b.level ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(b.ageing, 90)
    }

    func testAuthResponses() {
        XCTAssertEqual(NaoParser.parse([0xAA], channel: .security), .authResult(firstPairing: false))
        XCTAssertEqual(NaoParser.parse([0xA5], channel: .security), .authResult(firstPairing: true))
    }

    func testMorseSOS() {
        // S ... O --- S ... = 00 00 00 10 01 01 01 10 00 00 00 (11 symbols) + 11 terminator = 12
        let p = Morse.payload(for: "sos")
        XCTAssertEqual(p, [12, 0b0000_0010, 0b0101_0110, 0b0000_0011])
        XCTAssertEqual(NaoCommands.sos("sos")?.ackByte, 0xF5)
    }

    func testMorseWordGapAndNoTerminatorWhenAligned() {
        // "E E" = 00 11 00 -> 3 symbols, + terminator = 4 -> one byte
        XCTAssertEqual(Morse.payload(for: "E E"), [4, 0b0011_0011])
        // "TT" = 01 10 01 -> 3 + 11 = 4
        XCTAssertEqual(Morse.payload(for: "tt"), [4, 0b0110_0111])
        // "EEEE" would be E . E . E . E . -> 7 symbols + 11 = 8, byte-aligned
        XCTAssertEqual(Morse.payload(for: "EEEE")?.first, 8)
        XCTAssertNil(Morse.payload(for: "?!"))
        XCTAssertEqual(Morse.unsupported(in: "Olá!"), ["Á", "!"])
    }

    /// The factory Trail-running static values come out of the formula with a new battery.
    func testStaticCalculatorMatchesFactoryProfile() {
        let v = VariantCalculator.staticVariant(behavior: 3, autonomy: 720, ageing: 100)
        XCTAssertEqual(v.narrow, 40)
        XCTAssertEqual(v.wide, 80)
        let v3 = VariantCalculator.staticVariant(behavior: 3, autonomy: 180, ageing: 100)
        XCTAssertEqual(v3.narrow, 197, accuracy: 1)
        XCTAssertEqual(v3.wide, 394, accuracy: 2)
    }

    func testCalculatorNeverGoesNegative() {
        let v = VariantCalculator.staticVariant(behavior: 1, autonomy: 600, ageing: 3)
        XCTAssertGreaterThan(v.narrow, 0)
        XCTAssertTrue(VariantCalculator.capacity(ageing: 3, autonomy: 600).estimated)
    }

    func testFactoryProfilesLoad() throws {
        let profiles = try ProfileStore.loadFactoryProfiles()
        XCTAssertEqual(profiles.count, 6)
        XCTAssertTrue(profiles.allSatisfy { !$0.staticVariants.isEmpty && !$0.dynamicVariants.isEmpty })
        let write = NaoCommands.writeProfile(profiles[0])
        XCTAssertEqual(write.count, 3 + 3 + 3 + 1 + 9)
        XCTAssertTrue(write.allSatisfy { $0.bytes.count <= 20 })
    }
}
