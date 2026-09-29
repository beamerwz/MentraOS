import Foundation
import CoreBluetooth

@MainActor
final class G2Transport: NSObject, ObservableObject {
    static let service = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E0000")
    static let writeUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5401")
    static let notifyUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5402")
    static let audioUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E6402")

    @Published var bluetoothState = "Starting"
    @Published var discovered: [CBPeripheral] = []
    @Published var connectedName: String?
    @Published var controlPackets = 0
    @Published var audioPackets = 0
    @Published var audioBytes = 0
    @Published var lastAudioAt: Date?
    @Published var lastError: String?
    @Published var events: [String] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        log("Scanning for G2 service")
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        log("Connecting to \(p.name ?? p.identifier.uuidString)")
        central.connect(p)
    }

    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    private func log(_ s: String) {
        events.insert("\(Date().formatted(date: .omitted, time: .standard))  \(s)", at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }
}

extension G2Transport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bluetoothState = String(describing: central.state)
            log("Bluetooth state: \(bluetoothState)")
            if central.state == .poweredOn { scan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            if !discovered.contains(where: { $0.identifier == peripheral.identifier }) {
                discovered.append(peripheral)
                log("Found \(peripheral.name ?? "G2") RSSI \(RSSI)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedName = peripheral.name ?? "G2"
            log("Connected; discovering service")
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectedName = nil
            writeCharacteristic = nil
            audioCharacteristic = nil
            lastError = error?.localizedDescription
            log("Disconnected")
        }
    }
}

extension G2Transport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error { lastError = error.localizedDescription; return }
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID, Self.audioUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error { lastError = error.localizedDescription; return }
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case Self.writeUUID:
                    writeCharacteristic = c
                    log("Write characteristic ready")
                case Self.notifyUUID:
                    peripheral.setNotifyValue(true, for: c)
                    log("Control notifications armed")
                case Self.audioUUID:
                    audioCharacteristic = c
                    peripheral.setNotifyValue(true, for: c)
                    log("AUDIO notifications armed")
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let count = characteristic.value?.count ?? 0
        Task { @MainActor in
            if characteristic.uuid == Self.audioUUID {
                audioPackets += 1
                audioBytes += count
                lastAudioAt = Date()
            } else {
                controlPackets += 1
            }
        }
    }
}
