import CoreBluetooth
import Foundation

@MainActor
final class G2Transport: NSObject, ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var discoveredSerial = ""
    @Published private(set) var status = "Idle"

    var onPCM: ((Data) -> Void)?

    private let diagnostics: DiagnosticsStore
    private var central: CBCentralManager!
    private var left: CBPeripheral?
    private var right: CBPeripheral?
    private var leftWrite: CBCharacteristic?
    private var rightWrite: CBCharacteristic?
    private var leftNotify: CBCharacteristic?
    private var rightNotify: CBCharacteristic?
    private var leftAudio: CBCharacteristic?
    private var rightAudio: CBCharacteristic?
    private var targetSerial: String?
    private var syncID: UInt8 = 0
    private var magic: UInt8 = 0
    private var authStarted = false
    private var lastAudio: Data?
    private var heartbeat: Timer?
    private let decoder = PcmConverter()

    private let serviceUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E0000")
    private let writeUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5401")
    private let notifyUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5402")
    private let audioUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E6402")

    init(diagnostics: DiagnosticsStore) {
        self.diagnostics = diagnostics
        super.init()
        PcmConverter.setupStaticEncoderAndDecoder()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan() {
        status = "Scanning"
        diagnostics.bleState = "scanning"
        diagnostics.log("ble", "Scanning directly for Even G2")
        targetSerial = nil
        left = nil
        right = nil
        leftWrite = nil
        rightWrite = nil
        leftNotify = nil
        rightNotify = nil
        authStarted = false
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func disconnect() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let left { central.cancelPeripheralConnection(left) }
        if let right { central.cancelPeripheralConnection(right) }
        connected = false
        status = "Disconnected"
        diagnostics.bleState = "disconnected"
    }

    func sendCaption(_ text: String) {
        guard rightWrite != nil, !text.isEmpty else { return }
        let clipped = String(text.suffix(800))
        var update = ProtoWriter()
        update.int32(1, 1)
        update.int32(3, 0)
        update.int32(4, Int32(clipped.utf8.count))
        update.string(5, clipped)

        var hub = ProtoWriter()
        hub.int32(1, 5)
        hub.int32(2, nextMagic())
        hub.message(9, update.data)
        send(service: 0xE0, payload: hub.data, rightSide: true, reserve: true)
        diagnostics.displayWrites += 1
        diagnostics.log("display", "Caption sent to G2 (\(clipped.utf8.count) bytes)")
    }

    private func startSessionIfReady() {
        let leftReady = left != nil && leftWrite != nil
        let rightReady = right != nil && rightWrite != nil && rightNotify != nil
        guard leftReady, rightReady, !authStarted else { return }
        authStarted = true
        status = "Authenticating"
        diagnostics.log("ble", "Both lenses ready; starting standalone G2 auth")

        Task {
            sendAuth(leftSide: true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            sendAuth(leftSide: false)
            try? await Task.sleep(nanoseconds: 200_000_000)
            sendPipeRole()
            try? await Task.sleep(nanoseconds: 200_000_000)
            sendTimeSync()
            try? await Task.sleep(nanoseconds: 200_000_000)
            sendOnboardingFinish()
            try? await Task.sleep(nanoseconds: 350_000_000)
            createCaptionPage()
            try? await Task.sleep(nanoseconds: 350_000_000)
            setMic(false)
            try? await Task.sleep(nanoseconds: 500_000_000)
            setMic(true)

            connected = true
            status = "G2 mic armed"
            diagnostics.bleState = "ready"
            diagnostics.log("ble", "Standalone G2 session ready; audio control enabled")
            startHeartbeat()
        }
    }

    private func sendAuth(leftSide: Bool) {
        var auth = ProtoWriter()
        auth.bool(1, true)
        auth.int32(2, 3)
        var root = ProtoWriter()
        root.int32(1, 4)
        root.int32(2, nextMagic())
        root.message(3, auth.data)
        send(service: 0x80, payload: root.data, rightSide: !leftSide, leftSide: leftSide)
    }

    private func sendPipeRole() {
        var role = ProtoWriter()
        role.int32(1, 1)
        var root = ProtoWriter()
        root.int32(1, 5)
        root.int32(2, nextMagic())
        root.message(4, role.data)
        send(service: 0x80, payload: root.data, rightSide: true)
    }

    private func sendTimeSync() {
        let now = Date()
        let shifted = Int64(now.timeIntervalSince1970) + Int64(TimeZone.current.secondsFromGMT(for: now))
        var time = ProtoWriter()
        time.int32(1, Int32(truncatingIfNeeded: shifted))
        var root = ProtoWriter()
        root.int32(1, 128)
        root.int32(2, nextMagic())
        root.message(128, time.data)
        send(service: 0x80, payload: root.data, rightSide: true, leftSide: true)
    }

    private func sendOnboardingFinish() {
        var cfg = ProtoWriter()
        cfg.int32(1, 4)
        var root = ProtoWriter()
        root.int32(1, 1)
        root.int32(2, nextMagic())
        root.message(3, cfg.data)
        send(service: 0x10, payload: root.data, rightSide: true, reserve: true)
    }

    private func createCaptionPage() {
        var event = ProtoWriter()
        event.int32(1, 0); event.int32(2, 0); event.int32(3, 1); event.int32(4, 1)
        event.int32(5, 0); event.int32(6, 0); event.int32(7, 0); event.int32(8, 0)
        event.int32(9, 0); event.string(10, "evt-0"); event.int32(11, 1); event.string(12, "")

        var text = ProtoWriter()
        text.int32(1, 0); text.int32(2, 0); text.int32(3, 576); text.int32(4, 288)
        text.int32(5, 0); text.int32(6, 0); text.int32(7, 0); text.int32(8, 4)
        text.int32(9, 1); text.string(10, "g2labs-caption"); text.int32(11, 0)
        text.string(12, "G2 LABS · listening…")

        var page = ProtoWriter()
        page.int32(1, 2)
        page.message(3, event.data)
        page.message(3, text.data)

        var hub = ProtoWriter()
        hub.int32(1, 0)
        hub.int32(2, nextMagic())
        hub.message(3, page.data)
        send(service: 0xE0, payload: hub.data, rightSide: true, reserve: true)
        diagnostics.log("display", "Created standalone caption page")
    }

    private func setMic(_ enabled: Bool) {
        var mic = ProtoWriter()
        mic.int32(1, enabled ? 1 : 0)
        var hub = ProtoWriter()
        hub.int32(1, 15)
        hub.int32(2, nextMagic())
        hub.message(18, mic.data)
        send(service: 0xE0, payload: hub.data, rightSide: true, reserve: true)
        diagnostics.log("g2-mic", "audioControl=\(enabled)")
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                // Keep BOTH lenses alive, matching the proven G2 transport.
                var evenHubHeartbeat = ProtoWriter()
                var hubRoot = ProtoWriter()
                hubRoot.int32(1, 12)
                hubRoot.int32(2, self.nextMagic())
                hubRoot.message(14, evenHubHeartbeat.data)
                self.send(
                    service: 0xE0,
                    payload: hubRoot.data,
                    rightSide: true,
                    leftSide: true,
                    reserve: true
                )

                // Device-settings heartbeat is separate from EvenHub heartbeat.
                // Without both channels a lens can be reclaimed as idle.
                var deviceHeartbeat = ProtoWriter()
                var deviceRoot = ProtoWriter()
                deviceRoot.int32(1, 14)
                deviceRoot.int32(2, self.nextMagic())
                deviceRoot.message(13, deviceHeartbeat.data)
                self.send(
                    service: 0x80,
                    payload: deviceRoot.data,
                    rightSide: true,
                    leftSide: true,
                    reserve: false
                )
                self.diagnostics.log("ble", "Heartbeat sent to both lenses")
            }
        }
    }

    private func handleAudio(_ raw: Data) {
        let usable = Data(raw.prefix(min(raw.count, 200)))
        guard usable.count >= 40, usable != lastAudio else { return }
        lastAudio = usable
        diagnostics.lc3Frames += 1
        let pcm = decoder.decode(usable, frameSize: 40) as Data
        guard !pcm.isEmpty else {
            diagnostics.error("lc3", "LC3 decoder returned zero PCM bytes")
            return
        }
        diagnostics.pcmFrames += 1

        var peak: Int16 = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let magnitude = sample == Int16.min ? Int16.max : abs(sample)
                if magnitude > peak { peak = magnitude }
            }
        }
        diagnostics.audioLevel = Double(peak) / Double(Int16.max)
        if diagnostics.pcmFrames == 1 {
            diagnostics.log("pcm", "First G2 PCM frame: \(pcm.count) bytes")
        }
        onPCM?(pcm)
    }

    private func send(service: UInt8, payload: Data, rightSide: Bool = true, leftSide: Bool = false, reserve: Bool = false) {
        let packets = BLEFrame.build(sync: nextSync(), service: service, payload: payload, reserve: reserve)
        if rightSide, let p = right, let c = rightWrite { write(packets, peripheral: p, characteristic: c) }
        if leftSide, let p = left, let c = leftWrite { write(packets, peripheral: p, characteristic: c) }
    }

    private func write(_ packets: [Data], peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        for (i, packet) in packets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.006) {
                peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
            }
        }
    }

    private func nextSync() -> UInt8 { defer { syncID &+= 1 }; return syncID }
    private func nextMagic() -> Int32 { defer { magic &+= 1 }; return Int32(magic) }

    nonisolated private func serial(from manufacturer: Data) -> String? {
        guard manufacturer.count >= 16 else { return nil }
        return String(data: manufacturer.subdata(in: 2..<16), encoding: .ascii)?
            .replacingOccurrences(of: "[\\x00-\\x1F\\x7F]", with: "", options: .regularExpression)
    }
}

extension G2Transport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            diagnostics.bleState = String(describing: central.state)
            if central.state == .poweredOn { status = "Bluetooth ready" }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.contains("G2"),
              let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let sn = serial(from: mfg)
        else { return }

        Task { @MainActor in
            if targetSerial == nil { targetSerial = sn; discoveredSerial = sn }
            guard targetSerial == sn else { return }
            diagnostics.log("ble-scan", "\(name) SN=\(sn) RSSI=\(rssi)")
            peripheral.delegate = self
            if name.contains("_L_"), left == nil {
                left = peripheral
                central.connect(peripheral)
            } else if name.contains("_R_"), right == nil {
                right = peripheral
                central.connect(peripheral)
            }
            if left != nil && right != nil { central.stopScan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            diagnostics.log("ble", "Connected \(peripheral.name ?? peripheral.identifier.uuidString)")
            if peripheral === left { diagnostics.leftConnected = true }
            if peripheral === right { diagnostics.rightConnected = true }
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if peripheral === left { diagnostics.leftConnected = false; left = nil }
            if peripheral === right { diagnostics.rightConnected = false; right = nil }
            connected = false
            authStarted = false
            status = "Disconnected"
            diagnostics.error("ble", error?.localizedDescription ?? "G2 disconnected")
        }
    }
}

extension G2Transport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        Task { @MainActor in
            for char in chars {
                if char.uuid == writeUUID {
                    if peripheral === left { leftWrite = char } else if peripheral === right { rightWrite = char }
                } else if char.uuid == notifyUUID {
                    if peripheral === left { leftNotify = char } else if peripheral === right { rightNotify = char }
                    peripheral.setNotifyValue(true, for: char)
                } else if char.uuid == audioUUID {
                    if peripheral === left { leftAudio = char } else if peripheral === right { rightAudio = char }
                    peripheral.setNotifyValue(true, for: char)
                }
            }
            diagnostics.log("ble", "Characteristics ready on \(peripheral.name ?? "?")")
            startSessionIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == audioUUID {
            Task { @MainActor in handleAudio(value) }
        }
    }
}

private struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func int32(_ field: Int, _ value: Int32) {
        varint(UInt64(field << 3))
        if value >= 0 { varint(UInt64(value)) }
        else { varint(UInt64(bitPattern: Int64(value))) }
    }

    mutating func bool(_ field: Int, _ value: Bool) { int32(field, value ? 1 : 0) }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field << 3) | 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func message(_ field: Int, _ value: Data) { bytes(field, value) }
}

private enum BLEFrame {
    static func build(sync: UInt8, service: UInt8, payload: Data, reserve: Bool) -> [Data] {
        let maxPayload = 236
        var chunks: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(payload.count, offset + maxPayload)
            chunks.append(payload.subdata(in: offset..<end))
            offset = end
        }
        if chunks.isEmpty { chunks = [Data()] }
        if chunks.last?.count == maxPayload { chunks.append(Data()) }

        let total = UInt8(chunks.count)
        let crc = crc16(payload)
        return chunks.enumerated().map { index, chunk in
            let serial = UInt8(index + 1)
            let last = serial == total
            var packet = Data([0xAA, 0x21, sync, UInt8(chunk.count + (last ? 2 : 0)), total, serial, service, reserve ? 0x20 : 0x00])
            packet.append(chunk)
            if last {
                packet.append(UInt8(crc & 0xFF))
                packet.append(UInt8((crc >> 8) & 0xFF))
            }
            return packet
        }
    }

    private static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc = ((crc >> 8) | ((crc << 8) & 0xFF00)) ^ UInt16(byte)
            crc ^= (crc & 0xFF) >> 4
            crc ^= (crc << 12) & 0xFFFF
            crc ^= ((crc & 0xFF) << 5) & 0xFFFF
        }
        return crc
    }
}
