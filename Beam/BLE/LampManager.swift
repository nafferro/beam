import CoreBluetooth
import Foundation
import Observation

struct DiscoveredLamp: Identifiable, Equatable {
    let id: UUID
    let name: String
    let fid: String?
    var rssi: Int
    /// True when the advertisement carried Petzl's manufacturer prefix.
    let confirmedPetzl: Bool
    var isNao: Bool { fid.map { NaoGATT.naoFIDs.contains($0) } ?? false }
}

enum ConnectionState: Equatable {
    case bluetoothOff
    case idle
    case scanning
    case connecting
    case waitingForButton       // first pairing: press the lamp button
    case ready
    case failed(String)
}

/// Talks to one NAO+ over CoreBluetooth: scan, connect, authenticate,
/// then sends one command at a time and waits for its reply.
@MainActor
@Observable
final class LampManager: NSObject {
    // MARK: Public state
    private(set) var state: ConnectionState = .idle
    private(set) var discovered: [DiscoveredLamp] = []
    private(set) var connectedName: String?

    private(set) var lampName: String?
    private(set) var general: GeneralInfo?
    private(set) var battery: BatteryInfo?
    private(set) var software: SoftwareInfo?
    private(set) var batterySoftware: SoftwareInfo?
    private(set) var device: DeviceInfo?
    private(set) var profileName: String?
    private(set) var profileIsCustom = false
    private(set) var staticVariants: [StaticVariant?] = [nil, nil, nil]
    private(set) var dynamicVariants: [DynamicVariant?] = [nil, nil, nil]

    private(set) var pendingCommands = 0
    private(set) var liveActive = false
    private(set) var sosActive = false
    private(set) var log: [String] = []

    // MARK: Private
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var chars: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var notifyIndex = 0
    @ObservationIgnored private var queue: [Command] = []
    @ObservationIgnored private var current: Command?
    @ObservationIgnored private var chunks: [[UInt8]] = []
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var keyResendTask: Task<Void, Never>?
    @ObservationIgnored private var nameParts: [Int: [UInt8]] = [:]
    @ObservationIgnored private var liveBehavior = 1
    @ObservationIgnored private var liveIsStatic = true
    @ObservationIgnored private var liveSlot = 1

    private static let lastLampKey = "lastLampIdentifier"
    private static let ackTimeout: Duration = .milliseconds(1500)
    private static let maxRetries = 2

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Scanning

    func startScan() {
        guard central.state == .poweredOn else { state = .bluetoothOff; return }
        discovered.removeAll()
        state = .scanning
        // The lamp may not advertise its services, so scan everything and filter.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.state == .scanning else { return }
            self.stopScan()
        }
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    // MARK: - Connection

    func connect(_ lamp: DiscoveredLamp) {
        guard let p = central.retrievePeripherals(withIdentifiers: [lamp.id]).first else { return }
        central.stopScan()
        connect(peripheral: p)
    }

    private func connect(peripheral p: CBPeripheral) {
        resetSession()
        peripheral = p
        p.delegate = self
        connectedName = p.name
        state = .connecting
        addLog("Connecting to \(p.name ?? p.identifier.uuidString)")
        central.connect(p)
    }

    func reconnectLastLamp() {
        guard central.state == .poweredOn,
              let s = UserDefaults.standard.string(forKey: Self.lastLampKey),
              let id = UUID(uuidString: s),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        connect(peripheral: p)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetSession()
        state = .idle
    }

    func forgetLamp() {
        UserDefaults.standard.removeObject(forKey: Self.lastLampKey)
        disconnect()
    }

    private func resetSession() {
        timeoutTask?.cancel(); keyResendTask?.cancel()
        queue.removeAll(); current = nil; chunks.removeAll(); retries = 0
        chars.removeAll(); notifyIndex = 0; nameParts.removeAll()
        pendingCommands = 0; liveActive = false; sosActive = false
        lampName = nil; general = nil; battery = nil; software = nil; batterySoftware = nil; device = nil
        profileName = nil; staticVariants = [nil, nil, nil]; dynamicVariants = [nil, nil, nil]
    }

    // MARK: - Actions

    func refreshAll() {
        enqueue([NaoCommands.readGeneralInfo, NaoCommands.readBattery, NaoCommands.readLampName,
                 NaoCommands.readDevice, NaoCommands.readBatterySoftware] + NaoCommands.readProfile)
    }

    func refreshStatus() {
        enqueue([NaoCommands.readGeneralInfo, NaoCommands.readBattery])
    }

    func apply(profile: LampProfile) {
        addLog("Writing profile \(profile.lampName)")
        enqueue(NaoCommands.writeProfile(profile) + [NaoCommands.readGeneralInfo])
    }

    func setRedMode(_ mode: RedMode) {
        let n = general?.mode.variantNumber ?? 0
        enqueue([NaoCommands.setRedMode(mode, currentVariant: n), NaoCommands.readGeneralInfo])
    }

    /// Live mode works on the slot the lamp is using right now.
    func startLive() -> Bool {
        guard let mode = general?.mode else { return false }
        switch mode {
        case .constant(let n) where (1...3).contains(n):
            liveIsStatic = true; liveSlot = n
            liveBehavior = staticVariants[n - 1]?.behavior ?? 1
        case .reactive(let n) where (1...3).contains(n):
            liveIsStatic = false; liveSlot = n
            liveBehavior = dynamicVariants[n - 1]?.behavior ?? 1
        default:
            return false
        }
        if liveBehavior == 0 { liveBehavior = 1 }
        liveActive = true
        enqueue([NaoCommands.startLive])
        return true
    }

    var liveRange: ClosedRange<Int> {
        VariantCalculator.autonomyRange(behavior: liveBehavior, isStatic: liveIsStatic)
    }
    var liveDescription: String {
        "\(liveIsStatic ? "Constant" : "Reactive") \(liveSlot) · \(ProfileStore.behaviorNames[liveBehavior] ?? "behaviour \(liveBehavior)")"
    }
    var liveCurrentAutonomy: Int? {
        liveIsStatic ? staticVariants[liveSlot - 1]?.autonomy : dynamicVariants[liveSlot - 1]?.autonomy
    }

    func updateLive(autonomy: Int) {
        guard liveActive else { return }
        let ageing = battery?.ageing
        let cmd: Command
        if liveIsStatic {
            let v = VariantCalculator.staticVariant(behavior: liveBehavior, autonomy: autonomy, ageing: ageing)
            staticVariants[liveSlot - 1] = v
            cmd = NaoCommands.writeStatic(v, slot: liveSlot)
        } else {
            let v = VariantCalculator.dynamicVariant(behavior: liveBehavior, autonomy: autonomy, ageing: ageing)
            dynamicVariants[liveSlot - 1] = v
            cmd = NaoCommands.writeDynamic(v, slot: liveSlot)
        }
        // Keep only the latest slider value waiting in the queue.
        queue.removeAll { $0.bytes.prefix(2) == cmd.bytes.prefix(2) }
        enqueue([cmd])
    }

    func stopLive() {
        guard liveActive else { return }
        liveActive = false
        enqueue([NaoCommands.stopLive, NaoCommands.sync] + NaoCommands.readProfile)
    }

    func sendSOS(_ text: String) -> Bool {
        guard let cmd = NaoCommands.sos(text) else { return false }
        queue.removeAll()
        sosActive = true
        enqueue([cmd])
        return true
    }

    func stopSOS() {
        sosActive = false
        enqueue([NaoCommands.stopSOS])
    }

    // MARK: - Command queue

    private func enqueue(_ cmds: [Command]) {
        guard state == .ready else { return }
        queue.append(contentsOf: cmds)
        pendingCommands = queue.count + (current == nil ? 0 : 1)
        sendNext()
    }

    private func sendNext() {
        guard current == nil, !queue.isEmpty else {
            pendingCommands = queue.count + (current == nil ? 0 : 1)
            return
        }
        let cmd = queue.removeFirst()
        current = cmd
        retries = 0
        transmit(cmd)
    }

    private func transmit(_ cmd: Command) {
        guard let p = peripheral, let ch = characteristic(for: cmd.channel) else {
            addLog("No characteristic for \(cmd.label)")
            finishCurrent()
            return
        }
        // 20 bytes per write, like the original app.
        chunks = stride(from: 0, to: cmd.bytes.count, by: 20).map {
            Array(cmd.bytes[$0..<min($0 + 20, cmd.bytes.count)])
        }
        addLog("→ \(cmd.label): \(NaoParser.hex(cmd.bytes))")
        p.writeValue(Data(chunks.removeFirst()), for: ch, type: .withResponse)
        armTimeout()
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.ackTimeout)
            guard !Task.isCancelled, let self, let cmd = self.current else { return }
            if self.retries < Self.maxRetries {
                self.retries += 1
                self.addLog("no reply, retrying \(cmd.label)")
                self.transmit(cmd)
            } else {
                self.addLog("no reply, skipped: \(cmd.label)")
                self.finishCurrent()
            }
        }
    }

    private func finishCurrent() {
        timeoutTask?.cancel()
        current = nil
        sendNext()
    }

    private func characteristic(for channel: Channel) -> CBCharacteristic? {
        switch channel {
        case .security: chars[NaoGATT.securityWrite]
        case .light: chars[NaoGATT.lightWrite]
        case .battery: chars[NaoGATT.batteryWrite]
        }
    }

    // MARK: - Authentication

    private func sendSecurityKey() {
        guard let p = peripheral, let ch = chars[NaoGATT.securityWrite] else { return }
        addLog("→ security key")
        p.writeValue(Data(NaoCommands.securityKey.bytes), for: ch, type: .withResponse)
    }

    private func handleAuth(firstPairing: Bool) {
        if firstPairing {
            state = .waitingForButton
            addLog("First pairing: press the lamp button")
            // Resend the key every 3 s until the lamp answers AA (up to 45 s).
            keyResendTask?.cancel()
            keyResendTask = Task { [weak self] in
                for _ in 0..<15 {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self, self.state == .waitingForButton else { return }
                    self.sendSecurityKey()
                }
                guard let self, self.state == .waitingForButton else { return }
                self.state = .failed("The lamp button wasn't pressed in time.")
            }
        } else {
            keyResendTask?.cancel()
            guard state != .ready else { return }
            state = .ready
            if let id = peripheral?.identifier {
                UserDefaults.standard.set(id.uuidString, forKey: Self.lastLampKey)
            }
            addLog("Lamp ready")
            refreshAll()
        }
    }

    // MARK: - Incoming data

    private func handle(_ bytes: [UInt8], from uuid: CBUUID) {
        let channel: Channel = uuid == NaoGATT.securityNotify ? .security
            : uuid == NaoGATT.batteryNotify ? .battery : .light
        addLog("← \(NaoParser.hex(bytes))")
        if let cmd = current, let first = bytes.first, first == cmd.ackByte || (cmd.channel == .security && first == 0xA5) {
            finishCurrent()
        }
        guard let event = NaoParser.parse(bytes, channel: channel) else { return }
        switch event {
        case .authResult(let firstPairing): handleAuth(firstPairing: firstPairing)
        case .lampName(let s): lampName = s.isEmpty ? nil : s
        case .general(let g): general = g
        case .software(let s): software = s
        case .batterySoftware(let s): batterySoftware = s
        case .device(let d): device = d
        case .battery(let b): battery = b
        case .staticVariant(let slot, let v): staticVariants[slot - 1] = v.isEmpty ? nil : v
        case .dynamicVariant(let slot, let v): dynamicVariants[slot - 1] = v.isEmpty ? nil : v
        case .profileNamePart(let i, let b):
            nameParts[i] = b
            if nameParts.count == 3, let n = NaoParser.profileName(from: [nameParts[0]!, nameParts[1]!, nameParts[2]!]) {
                profileName = n.name
                profileIsCustom = n.custom || n.name.hasPrefix("My ")
                nameParts.removeAll()
            }
        case .ack(let b):
            if b == 0xF6 { sosActive = false }
        }
    }

    private func addLog(_ s: String) {
        let t = Date.now.formatted(date: .omitted, time: .standard)
        log.append("\(t)  \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    fileprivate func setState(_ s: ConnectionState) { state = s }
}

// MARK: - CBCentralManagerDelegate

extension LampManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                if state == .bluetoothOff { state = .idle }
                reconnectLastLamp()
            } else {
                state = .bluetoothOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let mfr = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let id = peripheral.identifier
        let periphName = peripheral.name
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            let name = advName ?? periphName ?? "Unnamed"
            var fid: String?
            var petzl = false
            if let m = mfr, m.count >= 2, Array(m.prefix(2)) == NaoGATT.manufacturerPrefix {
                petzl = true
                if m.count >= 4 { fid = String(format: "%02X%02X", m[3], m[2]) }
            }
            let looksLikePetzl = name.uppercased().contains("NAO") || name.uppercased().contains("PETZL")
            guard petzl || looksLikePetzl else { return }
            if let i = discovered.firstIndex(where: { $0.id == id }) {
                discovered[i].rssi = rssi
            } else {
                discovered.append(DiscoveredLamp(id: id, name: name, fid: fid, rssi: rssi, confirmedPetzl: petzl))
                addLog("Found: \(name) manufacturer=\(mfr.map { NaoParser.hex($0) } ?? "-")")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            addLog("Connected, discovering services")
            peripheral.discoverServices(NaoGATT.services)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "unknown error"
        MainActor.assumeIsolated { state = .failed("Couldn't connect: \(msg)") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription
        MainActor.assumeIsolated {
            addLog("Disconnected\(msg.map { ": \($0)" } ?? "")")
            let wasReady = state == .ready
            resetSession()
            state = wasReady ? .failed("Connection lost.") : (state == .idle ? .idle : .failed(msg ?? "Connection ended."))
        }
    }
}

// MARK: - CBPeripheralDelegate

extension LampManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            if services.count < 3 { addLog("Only \(services.count) of 3 services found") }
            for s in services { peripheral.discoverCharacteristics(nil, for: s) }
            if services.isEmpty { state = .failed("This lamp doesn't have the expected Petzl services.") }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] { chars[c.uuid] = c }
            let needed = [NaoGATT.securityWrite, NaoGATT.securityNotify, NaoGATT.lightWrite,
                          NaoGATT.lightNotify, NaoGATT.batteryWrite, NaoGATT.batteryNotify]
            if needed.allSatisfy({ chars[$0] != nil }), notifyIndex == 0 {
                enableNextNotification()
            }
        }
    }

    /// Notifications are switched on one at a time: security, light, battery. Then the key.
    private func enableNextNotification() {
        guard let p = peripheral else { return }
        if notifyIndex < NaoGATT.notifyOrder.count, let c = chars[NaoGATT.notifyOrder[notifyIndex]] {
            notifyIndex += 1
            p.setNotifyValue(true, for: c)
        } else if notifyIndex >= NaoGATT.notifyOrder.count {
            sendSecurityKey()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let msg = error?.localizedDescription
        MainActor.assumeIsolated {
            if let msg {
                addLog("Couldn't enable notifications: \(msg)")
                // An authentication error here means iOS is asking to pair; it retries by itself.
            }
            enableNextNotification()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let msg = error?.localizedDescription
        MainActor.assumeIsolated {
            if let msg { addLog("Write error: \(msg)") }
            // Send the next 20-byte chunk of a long frame.
            if !chunks.isEmpty, let p = self.peripheral {
                p.writeValue(Data(chunks.removeFirst()), for: characteristic, type: .withResponse)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        let bytes = [UInt8](data)
        MainActor.assumeIsolated { handle(bytes, from: uuid) }
    }
}
