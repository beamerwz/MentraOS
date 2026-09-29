import Foundation
import CoreBluetooth

struct G2PairCandidate: Identifiable, Equatable {
    let serial: String
    let leftName: String?
    let rightName: String?
    var id: String { serial }
    var complete: Bool { leftName != nil && rightName != nil }
}

enum G2PairingStage: Equatable {
    case bluetoothOff
    case scanning
    case waitingForBoth(String)
    case connecting(String)
    case authenticating(String)
    case ready(String)
    case failed(String)

    var title: String {
        switch self {
        case .bluetoothOff: return "Bluetooth unavailable"
        case .scanning: return "Looking for your G2"
        case .waitingForBoth: return "Finding both lenses"
        case .connecting: return "Connecting"
        case .authenticating: return "Authenticating G2"
        case .ready: return "G2 ready"
        case .failed: return "Pairing problem"
        }
    }

    var detail: String {
        switch self {
        case .bluetoothOff: return "Turn Bluetooth on to continue."
        case .scanning: return "Keep both glasses awake and close to this iPhone."
        case .waitingForBoth(let sn): return "Found part of \(sn). Waiting for left + right."
        case .connecting(let sn): return "Connecting both sides of \(sn)…"
        case .authenticating(let sn): return "Running the native G2 authentication sequence for \(sn)…"
        case .ready(let sn): return "\(sn) is authenticated and ready."
        case .failed(let message): return message
        }
    }
}

@MainActor
final class G2Transport: NSObject, ObservableObject {
    static let service = CBUUID(string: G2NativeProtocol.serviceUUID)
    static let writeUUID = CBUUID(string: G2NativeProtocol.writeUUID)
    static let notifyUUID = CBUUID(string: G2NativeProtocol.notifyUUID)
    static let audioUUID = CBUUID(string: G2NativeProtocol.audioUUID)

    @Published var bluetoothState = "Starting"
    @Published var candidates: [G2PairCandidate] = []
    @Published var pairingStage: G2PairingStage = .scanning
    @Published var connectedName: String?
    @Published var connectedSerial: String?
    @Published var controlPackets = 0
    @Published var audioPackets = 0
    @Published var audioBytes = 0
    @Published var lastAudioAt: Date?
    @Published var pcmChunks = 0
    @Published var pcmBytes: Int64 = 0
    @Published var pcmRMS: Double = 0
    @Published var micArmed = false
    @Published var captionUpdates = 0
    @Published var lastError: String?
    @Published var events: [String] = []

    let asr = NativeASRManager()

    var isReady: Bool {
        if case .ready = pairingStage { return true }
        return false
    }

    private var central: CBCentralManager!
    private var leftPeripheral: CBPeripheral?
    private var rightPeripheral: CBPeripheral?
    private var leftWrite: CBCharacteristic?
    private var rightWrite: CBCharacteristic?
    private var leftNotify: CBCharacteristic?
    private var rightNotify: CBCharacteristic?
    private var leftAudio: CBCharacteristic?
    private var rightAudio: CBCharacteristic?

    private var seen: [String: (left: CBPeripheral?, right: CBPeripheral?, leftName: String?, rightName: String?)] = [:]
    private var serialByPeripheral: [UUID: String] = [:]
    private var selectedSerial: String?
    private var authStarted = false
    private var leftAuthenticated = false
    private var rightAuthenticated = false
    private var runtimeStarted = false
    private var heartbeatTask: Task<Void, Never>?
    private var lastAudioFrame: Data?
    private let codec = G2PacketCodec()
    private let pcmConverter = PcmConverter()

    private let rememberedSerialKey = "G2NativeLabs.rememberedSerial"
    private let leftUUIDKey = "G2NativeLabs.leftUUID"
    private let rightUUIDKey = "G2NativeLabs.rightUUID"

    override init() {
        super.init()
        asr.onTranscript = { [weak self] text, final in
            guard let self else { return }
            self.displayCaption(text, isFinal: final)
        }
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    deinit {
        heartbeatTask?.cancel()
    }

    func scan() {
        guard central.state == .poweredOn else {
            pairingStage = .bluetoothOff
            return
        }
        log("Scanning for G2 advertisements")
        pairingStage = .scanning
        central.stopScan()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        if let remembered = UserDefaults.standard.string(forKey: rememberedSerialKey) {
            selectedSerial = remembered
            log("Auto-reconnect target: \(remembered)")
            tryReconnectKnownUUIDs()
        }
    }

    func pair(serial: String) {
        selectedSerial = serial
        guard let pair = seen[serial] else {
            pairingStage = .waitingForBoth(serial)
            return
        }
        guard let left = pair.left, let right = pair.right else {
            pairingStage = .waitingForBoth(serial)
            return
        }

        central.stopScan()
        resetLiveConnectionState()
        selectedSerial = serial
        leftPeripheral = left
        rightPeripheral = right
        left.delegate = self
        right.delegate = self
        serialByPeripheral[left.identifier] = serial
        serialByPeripheral[right.identifier] = serial
        pairingStage = .connecting(serial)
        log("Pairing \(serial): connecting LEFT + RIGHT")
        central.connect(left, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        central.connect(right, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    func forgetAndRescan() {
        if let leftPeripheral { central.cancelPeripheralConnection(leftPeripheral) }
        if let rightPeripheral { central.cancelPeripheralConnection(rightPeripheral) }
        UserDefaults.standard.removeObject(forKey: rememberedSerialKey)
        UserDefaults.standard.removeObject(forKey: leftUUIDKey)
        UserDefaults.standard.removeObject(forKey: rightUUIDKey)
        selectedSerial = nil
        connectedSerial = nil
        connectedName = nil
        resetLiveConnectionState()
        scan()
    }

    private func resetLiveConnectionState() {
        leftWrite = nil; rightWrite = nil
        leftNotify = nil; rightNotify = nil
        leftAudio = nil; rightAudio = nil
        authStarted = false
        leftAuthenticated = false
        rightAuthenticated = false
        runtimeStarted = false
        micArmed = false
        lastAudioFrame = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pcmConverter.resetDecoder()
    }

    private func tryReconnectKnownUUIDs() {
        guard let serial = selectedSerial,
              let l = UserDefaults.standard.string(forKey: leftUUIDKey).flatMap(UUID.init(uuidString:)),
              let r = UserDefaults.standard.string(forKey: rightUUIDKey).flatMap(UUID.init(uuidString:))
        else { return }

        let left = central.retrievePeripherals(withIdentifiers: [l]).first
        let right = central.retrievePeripherals(withIdentifiers: [r]).first
        guard let left, let right else { return }

        seen[serial] = (left, right, left.name, right.name)
        refreshCandidates()
        pair(serial: serial)
    }

    private func maybeAutoPair(_ serial: String) {
        guard selectedSerial == serial else { return }
        if seen[serial]?.left != nil && seen[serial]?.right != nil {
            pair(serial: serial)
        } else {
            pairingStage = .waitingForBoth(serial)
        }
    }

    private func refreshCandidates() {
        candidates = seen.map { serial, pair in
            G2PairCandidate(serial: serial, leftName: pair.leftName, rightName: pair.rightName)
        }.sorted { $0.serial < $1.serial }
    }

    private func runAuthSequenceIfReady() {
        guard !authStarted,
              leftWrite != nil,
              rightWrite != nil,
              rightNotify != nil,
              let serial = selectedSerial
        else { return }

        authStarted = true
        pairingStage = .authenticating(serial)
        log("Both sides initialized; starting G2 auth")
        Task { @MainActor in
            await send(service: G2NativeProtocol.deviceSettingsService,
                       payload: G2NativeProtocol.auth(magic: codec.nextMagic()),
                       toLeft: true, toRight: false)
            try? await Task.sleep(nanoseconds: 200_000_000)

            await send(service: G2NativeProtocol.deviceSettingsService,
                       payload: G2NativeProtocol.auth(magic: codec.nextMagic()),
                       toLeft: false, toRight: true)
            try? await Task.sleep(nanoseconds: 200_000_000)

            await send(service: G2NativeProtocol.deviceSettingsService,
                       payload: G2NativeProtocol.pipeRoleChange(magic: codec.nextMagic()),
                       toLeft: false, toRight: true)
            try? await Task.sleep(nanoseconds: 200_000_000)

            await send(service: G2NativeProtocol.deviceSettingsService,
                       payload: G2NativeProtocol.timeSync(magic: codec.nextMagic()),
                       toLeft: true, toRight: true)
            try? await Task.sleep(nanoseconds: 200_000_000)

            await send(service: G2NativeProtocol.onboardingService,
                       payload: G2NativeProtocol.onboardingFinish(magic: codec.nextMagic()),
                       reserve: true, toLeft: false, toRight: true)
            log("Native auth sequence sent")
        }
    }

    private func send(service: UInt8, payload: Data, reserve: Bool = false,
                      toLeft: Bool, toRight: Bool) async {
        let packets = codec.packets(service: service, payload: payload, reserve: reserve)
        for packet in packets {
            if toLeft, let p = leftPeripheral, let c = leftWrite {
                p.writeValue(packet, for: c, type: .withoutResponse)
            }
            if toRight, let p = rightPeripheral, let c = rightWrite {
                p.writeValue(packet, for: c, type: .withoutResponse)
            }
            try? await Task.sleep(nanoseconds: 6_000_000)
        }
    }

    private func processControl(_ raw: Data, from peripheral: CBPeripheral) {
        controlPackets += 1
        let side = peripheral === leftPeripheral ? "L" : "R"
        guard let (service, payload) = codec.receive(raw, side: side) else { return }
        guard service == G2NativeProtocol.deviceSettingsService,
              let authenticated = G2NativeProtocol.parseAuthResponse(payload)
        else { return }

        log("Auth response \(side): \(authenticated ? "OK" : "DENIED")")
        if authenticated {
            if side == "L" { leftAuthenticated = true } else { rightAuthenticated = true }
        }

        if leftAuthenticated && rightAuthenticated, let serial = selectedSerial, !isReady {
            connectedSerial = serial
            connectedName = rightPeripheral?.name ?? leftPeripheral?.name ?? "Even G2"
            pairingStage = .ready(serial)
            UserDefaults.standard.set(serial, forKey: rememberedSerialKey)
            if let id = leftPeripheral?.identifier.uuidString {
                UserDefaults.standard.set(id, forKey: leftUUIDKey)
            }
            if let id = rightPeripheral?.identifier.uuidString {
                UserDefaults.standard.set(id, forKey: rightUUIDKey)
            }
            log("PAIRING PASS: both lenses authenticated")
            startRuntimeSession()
        }
    }

    private func startRuntimeSession() {
        guard !runtimeStarted else { return }
        runtimeStarted = true
        log("Creating native EvenHub caption page")

        Task { @MainActor in
            await send(
                service: G2NativeProtocol.evenHubService,
                payload: G2NativeProtocol.createCaptionPage(text: "G2 LABS\nPreparing microphone…", magic: codec.nextMagic()),
                reserve: true,
                toLeft: false,
                toRight: true
            )

            try? await Task.sleep(nanoseconds: 350_000_000)

            await send(
                service: G2NativeProtocol.evenHubService,
                payload: G2NativeProtocol.audioControl(enabled: false, magic: codec.nextMagic()),
                reserve: true,
                toLeft: false,
                toRight: true
            )

            try? await Task.sleep(nanoseconds: 500_000_000)

            await send(
                service: G2NativeProtocol.evenHubService,
                payload: G2NativeProtocol.audioControl(enabled: true, magic: codec.nextMagic()),
                reserve: true,
                toLeft: false,
                toRight: true
            )

            micArmed = true
            log("G2 MIC ARMED: live page + OFF→ON audio edge sent")
            await updateCaptionOnGlasses(asr.state.isReady ? "Listening…" : "G2 LABS\nImport + activate a model")

            heartbeatTask?.cancel()
            heartbeatTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.isReady {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { break }
                    await self.send(
                        service: G2NativeProtocol.deviceSettingsService,
                        payload: G2NativeProtocol.baseHeartbeat(magic: self.codec.nextMagic()),
                        toLeft: true,
                        toRight: true
                    )
                    await self.send(
                        service: G2NativeProtocol.evenHubService,
                        payload: G2NativeProtocol.evenHubHeartbeat(magic: self.codec.nextMagic()),
                        reserve: true,
                        toLeft: false,
                        toRight: true
                    )
                }
            }
        }
    }

    func ensureRuntimeAlive(reason: String) {
        guard isReady else { return }
        let staleAudio: Bool
        if let lastAudioAt {
            staleAudio = Date().timeIntervalSince(lastAudioAt) > 1.5
        } else {
            staleAudio = true
        }

        log("Runtime keepalive: \(reason) • staleAudio=\(staleAudio)")

        Task { @MainActor in
            await send(
                service: G2NativeProtocol.deviceSettingsService,
                payload: G2NativeProtocol.baseHeartbeat(magic: codec.nextMagic()),
                toLeft: true,
                toRight: true
            )
            await send(
                service: G2NativeProtocol.evenHubService,
                payload: G2NativeProtocol.evenHubHeartbeat(magic: codec.nextMagic()),
                reserve: true,
                toLeft: false,
                toRight: true
            )

            if staleAudio || !micArmed {
                await send(
                    service: G2NativeProtocol.evenHubService,
                    payload: G2NativeProtocol.audioControl(enabled: false, magic: codec.nextMagic()),
                    reserve: true,
                    toLeft: false,
                    toRight: true
                )
                try? await Task.sleep(nanoseconds: 180_000_000)
                await send(
                    service: G2NativeProtocol.evenHubService,
                    payload: G2NativeProtocol.audioControl(enabled: true, magic: codec.nextMagic()),
                    reserve: true,
                    toLeft: false,
                    toRight: true
                )
                micArmed = true
                log("Runtime recovered: G2 mic OFF→ON re-armed")
            }

            let statusText: String
            if !asr.partialText.isEmpty {
                statusText = asr.partialText
            } else if !asr.finalText.isEmpty {
                statusText = asr.finalText
            } else if asr.state.isReady {
                statusText = "Listening…"
            } else {
                statusText = "G2 LABS\nImport + activate a model"
            }
            await updateCaptionOnGlasses(statusText)
        }
    }

    func applicationDidBecomeActive() {
        ensureRuntimeAlive(reason: "app returned active")
    }

    func activateModel(_ model: ASRModel, directory: URL) {
        log("Loading ASR model: \(model.name) [\(model.family.rawValue)]")
        asr.load(modelName: model.name, directory: directory, family: model.family, language: "it")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await updateCaptionOnGlasses("Loading \(model.name)…")
        }
    }

    private func displayCaption(_ text: String, isFinal: Bool) {
        guard !text.isEmpty, isReady else { return }
        captionUpdates += 1
        log("\(isFinal ? "FINAL" : "PARTIAL"): \(text.prefix(90))")
        Task { @MainActor [weak self] in
            await self?.updateCaptionOnGlasses(text)
        }
    }

    private func updateCaptionOnGlasses(_ text: String) async {
        await send(
            service: G2NativeProtocol.evenHubService,
            payload: G2NativeProtocol.updateCaption(text: text, magic: codec.nextMagic()),
            reserve: true,
            toLeft: false,
            toRight: true
        )
    }

    private func handleAudioPacket(_ data: Data) {
        audioPackets += 1
        audioBytes += data.count
        lastAudioAt = Date()

        let usableLength = min(data.count, 200)
        guard usableLength >= 40 else {
            log("AUDIO packet too short: \(data.count) bytes")
            return
        }

        let audio = Data(data.prefix(usableLength))
        if lastAudioFrame == audio { return }
        lastAudioFrame = audio

        let pcm = pcmConverter.decode(audio, frameSize: 40) as Data
        guard !pcm.isEmpty else {
            log("LC3 decode returned 0 PCM bytes")
            return
        }

        pcmChunks += 1
        pcmBytes += Int64(pcm.count)
        pcmRMS = Self.rms(ofPCM16LE: pcm)
        asr.acceptPCM(pcm)
    }

    private static func rms(ofPCM16LE data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        let meanSquare: Double = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            let samples = base.bindMemory(to: Int16.self, capacity: count)
            var sum = 0.0
            for i in 0..<count {
                let v = Double(Int16(littleEndian: samples[i])) / 32768.0
                sum += v * v
            }
            return sum / Double(count)
        }
        return sqrt(meanSquare)
    }

    private func log(_ text: String) {
        events.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0)
        if events.count > 150 { events.removeLast(events.count - 150) }
    }
}

extension G2Transport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "On"
                scan()
            case .poweredOff:
                bluetoothState = "Off"
                pairingStage = .bluetoothOff
            case .unauthorized:
                bluetoothState = "Unauthorized"
                pairingStage = .failed("Bluetooth permission is not available.")
            default:
                bluetoothState = "Starting"
            }
            log("Bluetooth state: \(bluetoothState)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        guard let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              name.contains("G2"),
              let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let serial = G2NativeProtocol.serial(from: mfg)
        else { return }

        Task { @MainActor in
            serialByPeripheral[peripheral.identifier] = serial
            var pair = seen[serial] ?? (nil, nil, nil, nil)
            if name.contains("_L_") {
                pair.left = peripheral
                pair.leftName = name
            } else if name.contains("_R_") {
                pair.right = peripheral
                pair.rightName = name
            } else {
                return
            }
            seen[serial] = pair
            refreshCandidates()
            log("Found \(name) • SN \(serial) • RSSI \(RSSI)")
            maybeAutoPair(serial)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            log("Connected BLE: \(peripheral.name ?? peripheral.identifier.uuidString)")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            let message = error?.localizedDescription ?? "Unknown connection failure"
            lastError = message
            pairingStage = .failed(message)
            log("Connect failed: \(message)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            let wasActive = peripheral === leftPeripheral || peripheral === rightPeripheral
            if wasActive {
                connectedName = nil
                connectedSerial = nil
                resetLiveConnectionState()
                let message = error?.localizedDescription ?? "G2 disconnected"
                lastError = message
                log(message)
                if let serial = selectedSerial {
                    pairingStage = .waitingForBoth(serial)
                    scan()
                }
            }
        }
    }
}

extension G2Transport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                pairingStage = .failed(error.localizedDescription)
                return
            }
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                pairingStage = .failed(error.localizedDescription)
                return
            }

            let isLeft = peripheral === leftPeripheral
            for c in service.characteristics ?? [] {
                if c.uuid == Self.writeUUID {
                    if isLeft { leftWrite = c } else { rightWrite = c }
                    log("\(isLeft ? "LEFT" : "RIGHT") write ready")
                } else if c.uuid == Self.notifyUUID {
                    if isLeft { leftNotify = c } else { rightNotify = c }
                    peripheral.setNotifyValue(true, for: c)
                    log("\(isLeft ? "LEFT" : "RIGHT") control notify armed")
                } else if c.uuid == Self.audioUUID {
                    if isLeft { leftAudio = c } else { rightAudio = c }
                    peripheral.setNotifyValue(true, for: c)
                    log("\(isLeft ? "LEFT" : "RIGHT") audio notify armed")
                }
            }
            runAuthSequenceIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        Task { @MainActor in
            if characteristic.uuid == Self.audioUUID {
                handleAudioPacket(data)
            } else if characteristic.uuid == Self.notifyUUID {
                processControl(data, from: peripheral)
            }
        }
    }
}
