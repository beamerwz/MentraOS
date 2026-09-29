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
        case .scanning: return "Mentra G2 transport is scanning for both lenses."
        case .waitingForBoth(let sn): return "Found part of \(sn). Waiting for left + right."
        case .connecting(let sn): return "Connecting both sides of \(sn)…"
        case .authenticating(let sn): return "Running the G2 authentication/session sequence for \(sn)…"
        case .ready(let sn): return "\(sn) is authenticated and the EvenHub runtime is managed."
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
    private var selectedSerial: String?

    private var authStarted = false
    private var leftAuthenticated = false
    private var rightAuthenticated = false

    // Mentra G2 keeps the EvenHub page/mic lifecycle separate from BLE.
    private var runtimeStarted = false
    private var pageCreated = false
    private var evenHubMicActive = false
    private var micIntent = true
    private var recoveryInFlight = false
    private var lastRecoveryAt = Date.distantPast
    private let recoveryDebounce: TimeInterval = 0.8
    private var lastCaptionText = "G2 LABS"

    // Mentra-style paced FIFO writes. This avoids burst-writing packets while
    // model initialization or UI work is stressing the main run loop.
    private var leftWriteQueue: [Data] = []
    private var rightWriteQueue: [Data] = []
    private var leftDraining = false
    private var rightDraining = false
    private let writePaceNanos: UInt64 = 6_000_000

    private var heartbeatTask: Task<Void, Never>?
    private var audioWatchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var intentionalDisconnect = false

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

        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    deinit {
        heartbeatTask?.cancel()
        audioWatchdogTask?.cancel()
        reconnectTask?.cancel()
    }

    // MARK: - Mentra-derived pairing / reconnect

    func scan() {
        guard central.state == .poweredOn else {
            pairingStage = .bluetoothOff
            return
        }

        intentionalDisconnect = false
        central.stopScan()

        if let remembered = UserDefaults.standard.string(forKey: rememberedSerialKey) {
            selectedSerial = remembered
            if connectKnownPair(serial: remembered) {
                log("Mentra-style UUID reconnect target: \(remembered)")
                return
            }
        }

        pairingStage = .scanning
        log("Mentra G2 scan started")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
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

        connectPair(serial: serial, left: left, right: right)
    }

    private func connectKnownPair(serial: String) -> Bool {
        guard
            let leftID = UserDefaults.standard.string(forKey: leftUUIDKey).flatMap(UUID.init(uuidString:)),
            let rightID = UserDefaults.standard.string(forKey: rightUUIDKey).flatMap(UUID.init(uuidString:))
        else { return false }

        guard
            let left = central.retrievePeripherals(withIdentifiers: [leftID]).first,
            let right = central.retrievePeripherals(withIdentifiers: [rightID]).first
        else { return false }

        seen[serial] = (left, right, left.name, right.name)
        refreshCandidates()
        connectPair(serial: serial, left: left, right: right)
        return true
    }

    private func connectPair(serial: String, left: CBPeripheral, right: CBPeripheral) {
        central.stopScan()
        resetLiveConnectionState()

        selectedSerial = serial
        leftPeripheral = left
        rightPeripheral = right
        left.delegate = self
        right.delegate = self

        pairingStage = .connecting(serial)
        log("Mentra transport connecting LEFT + RIGHT for \(serial)")

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
        intentionalDisconnect = true
        heartbeatTask?.cancel()
        audioWatchdogTask?.cancel()
        reconnectTask?.cancel()

        if let leftPeripheral { central.cancelPeripheralConnection(leftPeripheral) }
        if let rightPeripheral { central.cancelPeripheralConnection(rightPeripheral) }

        UserDefaults.standard.removeObject(forKey: rememberedSerialKey)
        UserDefaults.standard.removeObject(forKey: leftUUIDKey)
        UserDefaults.standard.removeObject(forKey: rightUUIDKey)

        selectedSerial = nil
        connectedSerial = nil
        connectedName = nil
        seen.removeAll()
        candidates.removeAll()
        resetLiveConnectionState()

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.intentionalDisconnect = false
            self?.scan()
        }
    }

    private func scheduleReconnect() {
        guard !intentionalDisconnect else { return }
        reconnectTask?.cancel()

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled && !self.isReady {
                attempt += 1
                self.log("Mentra reconnect attempt \(attempt)")

                if let serial = self.selectedSerial,
                   self.connectKnownPair(serial: serial) {
                    // Connection callbacks decide when ready.
                } else {
                    self.scan()
                }

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func refreshCandidates() {
        candidates = seen.map { serial, pair in
            G2PairCandidate(
                serial: serial,
                leftName: pair.leftName,
                rightName: pair.rightName
            )
        }.sorted { $0.serial < $1.serial }
    }

    private func resetLiveConnectionState() {
        leftWrite = nil
        rightWrite = nil
        leftNotify = nil
        rightNotify = nil
        leftAudio = nil
        rightAudio = nil

        leftWriteQueue.removeAll()
        rightWriteQueue.removeAll()
        leftDraining = false
        rightDraining = false

        authStarted = false
        leftAuthenticated = false
        rightAuthenticated = false

        runtimeStarted = false
        pageCreated = false
        evenHubMicActive = false
        micArmed = false
        recoveryInFlight = false

        lastAudioFrame = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        pcmConverter.resetDecoder()
    }

    // MARK: - Mentra-style paced write queues

    private func enqueue(_ packets: [Data], right: Bool) {
        guard !packets.isEmpty else { return }

        if right {
            rightWriteQueue.append(contentsOf: packets)
            startDrain(right: true)
        } else {
            leftWriteQueue.append(contentsOf: packets)
            startDrain(right: false)
        }
    }

    private func startDrain(right: Bool) {
        if right {
            if rightDraining { return }
            rightDraining = true
        } else {
            if leftDraining { return }
            leftDraining = true
        }

        Task { @MainActor [weak self] in
            await self?.drainLoop(right: right)
        }
    }

    private func drainLoop(right: Bool) async {
        while true {
            guard
                let peripheral = right ? rightPeripheral : leftPeripheral,
                let characteristic = right ? rightWrite : leftWrite
            else {
                if right {
                    rightWriteQueue.removeAll()
                    rightDraining = false
                } else {
                    leftWriteQueue.removeAll()
                    leftDraining = false
                }
                return
            }

            if right ? rightWriteQueue.isEmpty : leftWriteQueue.isEmpty {
                if right { rightDraining = false }
                else { leftDraining = false }
                return
            }

            let packet = right
                ? rightWriteQueue.removeFirst()
                : leftWriteQueue.removeFirst()

            peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
            try? await Task.sleep(nanoseconds: writePaceNanos)
        }
    }

    private func send(
        service: UInt8,
        payload: Data,
        reserve: Bool = false,
        toLeft: Bool,
        toRight: Bool
    ) async {
        let packets = codec.packets(service: service, payload: payload, reserve: reserve)

        if toLeft { enqueue(packets, right: false) }
        if toRight { enqueue(packets, right: true) }

        // Preserve sequencing between protocol phases without depending on
        // CoreBluetooth's write-ready callback, matching Mentra's G2 drainer.
        let settle = UInt64(max(1, packets.count)) * writePaceNanos
        try? await Task.sleep(nanoseconds: settle)
    }

    // MARK: - Auth / runtime

    private func runAuthSequenceIfReady() {
        guard
            !authStarted,
            leftWrite != nil,
            rightWrite != nil,
            rightNotify != nil,
            let serial = selectedSerial
        else { return }

        authStarted = true
        pairingStage = .authenticating(serial)
        log("Both lenses initialized; starting G2 auth")

        Task { @MainActor [weak self] in
            guard let self else { return }

            await self.send(
                service: G2NativeProtocol.deviceSettingsService,
                payload: G2NativeProtocol.auth(magic: self.codec.nextMagic()),
                toLeft: true,
                toRight: false
            )
            try? await Task.sleep(nanoseconds: 200_000_000)

            await self.send(
                service: G2NativeProtocol.deviceSettingsService,
                payload: G2NativeProtocol.auth(magic: self.codec.nextMagic()),
                toLeft: false,
                toRight: true
            )
            try? await Task.sleep(nanoseconds: 200_000_000)

            await self.send(
                service: G2NativeProtocol.deviceSettingsService,
                payload: G2NativeProtocol.pipeRoleChange(magic: self.codec.nextMagic()),
                toLeft: false,
                toRight: true
            )
            try? await Task.sleep(nanoseconds: 200_000_000)

            await self.send(
                service: G2NativeProtocol.deviceSettingsService,
                payload: G2NativeProtocol.timeSync(magic: self.codec.nextMagic()),
                toLeft: true,
                toRight: true
            )
            try? await Task.sleep(nanoseconds: 200_000_000)

            await self.send(
                service: G2NativeProtocol.onboardingService,
                payload: G2NativeProtocol.onboardingFinish(magic: self.codec.nextMagic()),
                reserve: true,
                toLeft: false,
                toRight: true
            )

            self.log("G2 auth sequence sent")
        }
    }

    private func processControl(_ raw: Data, from peripheral: CBPeripheral) {
        controlPackets += 1
        let side = peripheral === leftPeripheral ? "L" : "R"

        guard let (service, payload) = codec.receive(raw, side: side) else { return }

        if service == G2NativeProtocol.evenHubService {
            if G2NativeProtocol.evenHubPageWasShutdown(payload) {
                pageCreated = false
                evenHubMicActive = false
                micArmed = false
                log("Mentra lifecycle: glasses shut down EvenHub page")
                recoverPageAndMic(reason: "firmware page shutdown")
            }
            return
        }

        guard
            service == G2NativeProtocol.deviceSettingsService,
            let authenticated = G2NativeProtocol.parseAuthResponse(payload)
        else { return }

        log("Auth response \(side): \(authenticated ? "OK" : "DENIED")")

        if authenticated {
            if side == "L" { leftAuthenticated = true }
            else { rightAuthenticated = true }
        }

        guard leftAuthenticated && rightAuthenticated,
              let serial = selectedSerial,
              !isReady
        else { return }

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

        reconnectTask?.cancel()
        reconnectTask = nil
        log("PAIRING PASS: Mentra-style dual-lens session authenticated")
        startRuntimeSession()
    }

    private func startRuntimeSession() {
        guard !runtimeStarted else { return }
        runtimeStarted = true
        micIntent = true

        startHeartbeats()
        startAudioWatchdog()
        recoverPageAndMic(reason: "initial runtime")
    }

    private func startHeartbeats() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isReady {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, self.isReady else { break }
                await self.sendHeartbeats()
            }
        }
    }

    private func startAudioWatchdog() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled && self.isReady {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.isReady else { break }

                let stale = self.audioIsStale(threshold: 2.5)
                if stale {
                    self.log("Mentra watchdog: G2 audio stale while BLE is still connected")
                    self.recoverPageAndMic(reason: "audio watchdog")
                }
            }
        }
    }

    private func sendHeartbeats() async {
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
    }

    private func audioIsStale(threshold: TimeInterval) -> Bool {
        guard micIntent else { return false }
        guard let lastAudioAt else { return true }
        return Date().timeIntervalSince(lastAudioAt) > threshold
    }

    private func recoverPageAndMic(reason: String) {
        guard isReady else { return }

        let now = Date()
        if recoveryInFlight { return }
        if now.timeIntervalSince(lastRecoveryAt) < recoveryDebounce { return }

        recoveryInFlight = true
        lastRecoveryAt = now
        log("Mentra recovery (\(reason)): rebuilding page + mic")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recoveryInFlight = false }

            await self.sendHeartbeats()

            if !self.pageCreated {
                let initialText: String
                if !self.asr.partialText.isEmpty {
                    initialText = self.asr.partialText
                } else if !self.asr.finalText.isEmpty {
                    initialText = self.asr.finalText
                } else if self.asr.state.isReady {
                    initialText = "Listening…"
                } else {
                    initialText = "G2 LABS\nImport + activate a model"
                }

                self.lastCaptionText = initialText
                await self.send(
                    service: G2NativeProtocol.evenHubService,
                    payload: G2NativeProtocol.createCaptionPage(
                        text: initialText,
                        magic: self.codec.nextMagic()
                    ),
                    reserve: true,
                    toLeft: false,
                    toRight: true
                )
                self.pageCreated = true
                self.log("Mentra lifecycle: EvenHub caption page created")
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            if self.micIntent {
                await self.restartMic()
            }
        }
    }

    private func restartMic() async {
        guard isReady, pageCreated else {
            pageCreated = false
            evenHubMicActive = false
            micArmed = false
            return
        }

        // Mentra deliberately forces a new audio edge when the stream is stale,
        // even if its previous logical mic state was already "on".
        await send(
            service: G2NativeProtocol.evenHubService,
            payload: G2NativeProtocol.audioControl(
                enabled: false,
                magic: codec.nextMagic()
            ),
            reserve: true,
            toLeft: false,
            toRight: true
        )
        evenHubMicActive = false
        micArmed = false

        try? await Task.sleep(nanoseconds: 220_000_000)

        await send(
            service: G2NativeProtocol.evenHubService,
            payload: G2NativeProtocol.audioControl(
                enabled: true,
                magic: codec.nextMagic()
            ),
            reserve: true,
            toLeft: false,
            toRight: true
        )

        evenHubMicActive = true
        micArmed = true
        log("Mentra lifecycle: G2 microphone re-armed OFF→ON")
    }

    func ensureRuntimeAlive(reason: String) {
        guard isReady else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendHeartbeats()

            if !self.pageCreated || !self.evenHubMicActive || self.audioIsStale(threshold: 1.5) {
                self.recoverPageAndMic(reason: reason)
            }
        }
    }

    func applicationDidBecomeActive() {
        ensureRuntimeAlive(reason: "app became active")
    }

    // MARK: - ASR / captions

    func activateModel(_ model: ASRModel, directory: URL) {
        log("Loading ASR model: \(model.name) [\(model.family.rawValue)]")

        asr.load(
            modelName: model.name,
            directory: directory,
            family: model.family,
            language: "it-IT"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.lastCaptionText = "Loading \(model.name)…"
            if self.pageCreated {
                await self.updateCaptionOnGlasses(self.lastCaptionText)
            }

            // Keep the Mentra-managed runtime alive while ORT builds the model.
            var seconds = 0
            while case .loading = self.asr.state, seconds < 90 {
                if seconds % 2 == 0 {
                    await self.sendHeartbeats()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                seconds += 1
            }

            self.ensureRuntimeAlive(reason: "ASR model load finished")
        }
    }

    private func displayCaption(_ text: String, isFinal: Bool) {
        guard !text.isEmpty, isReady else { return }

        captionUpdates += 1
        lastCaptionText = text
        log("\(isFinal ? "FINAL" : "PARTIAL"): \(text.prefix(90))")

        Task { @MainActor [weak self] in
            guard let self else { return }

            if !self.pageCreated {
                self.recoverPageAndMic(reason: "caption while page absent")
                return
            }

            await self.updateCaptionOnGlasses(text)
        }
    }

    private func updateCaptionOnGlasses(_ text: String) async {
        guard pageCreated else { return }

        await send(
            service: G2NativeProtocol.evenHubService,
            payload: G2NativeProtocol.updateCaption(
                text: text,
                magic: codec.nextMagic()
            ),
            reserve: true,
            toLeft: false,
            toRight: true
        )
    }

    // MARK: - G2 microphone

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
                let value = Double(Int16(littleEndian: samples[i])) / 32768.0
                sum += value * value
            }

            return sum / Double(count)
        }

        return sqrt(meanSquare)
    }

    private func log(_ text: String) {
        events.insert(
            "\(Date().formatted(date: .omitted, time: .standard))  \(text)",
            at: 0
        )
        if events.count > 180 {
            events.removeLast(events.count - 180)
        }
    }
}

// MARK: - CBCentralManagerDelegate

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
            case .unsupported:
                bluetoothState = "Unsupported"
                pairingStage = .failed("Bluetooth is unsupported on this device.")
            default:
                bluetoothState = "Starting"
            }

            log("Bluetooth state: \(bluetoothState)")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard
            let name = peripheral.name
                ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            name.contains("G2"),
            let manufacturerData =
                advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            let serial = G2NativeProtocol.serial(from: manufacturerData)
        else { return }

        Task { @MainActor in
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

            guard selectedSerial == serial else { return }

            if let left = pair.left, let right = pair.right {
                connectPair(serial: serial, left: left, right: right)
            } else {
                pairingStage = .waitingForBoth(serial)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        Task { @MainActor in
            log("Connected BLE: \(peripheral.name ?? peripheral.identifier.uuidString)")
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let message = error?.localizedDescription ?? "Unknown connection failure"
            lastError = message
            pairingStage = .failed(message)
            log("Connect failed: \(message)")
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard peripheral === leftPeripheral || peripheral === rightPeripheral else {
                return
            }

            let message = error?.localizedDescription ?? "G2 disconnected"
            log("Mentra transport disconnect: \(message)")

            connectedName = nil
            connectedSerial = nil

            // Mentra resets both halves after either side disappears so the next
            // session is always a coherent L+R pair.
            if let other = peripheral === leftPeripheral ? rightPeripheral : leftPeripheral,
               other.state == .connected {
                central.cancelPeripheralConnection(other)
            }

            resetLiveConnectionState()

            if intentionalDisconnect { return }

            if let serial = selectedSerial {
                pairingStage = .waitingForBoth(serial)
            } else {
                pairingStage = .scanning
            }

            scheduleReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension G2Transport: CBPeripheralDelegate {
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
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

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                pairingStage = .failed(error.localizedDescription)
                return
            }

            let isLeft = peripheral === leftPeripheral

            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.writeUUID {
                    if isLeft { leftWrite = characteristic }
                    else { rightWrite = characteristic }
                    log("\(isLeft ? "LEFT" : "RIGHT") write ready")
                } else if characteristic.uuid == Self.notifyUUID {
                    if isLeft { leftNotify = characteristic }
                    else { rightNotify = characteristic }
                    peripheral.setNotifyValue(true, for: characteristic)
                    log("\(isLeft ? "LEFT" : "RIGHT") control notify armed")
                } else if characteristic.uuid == Self.audioUUID {
                    if isLeft { leftAudio = characteristic }
                    else { rightAudio = characteristic }
                    peripheral.setNotifyValue(true, for: characteristic)
                    log("\(isLeft ? "LEFT" : "RIGHT") audio notify armed")
                }
            }

            runAuthSequenceIfReady()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        Task { @MainActor in
            if characteristic.uuid == Self.audioUUID {
                handleAudioPacket(data)
            } else if characteristic.uuid == Self.notifyUUID {
                processControl(data, from: peripheral)
            }
        }
    }

    nonisolated func peripheralIsReady(
        toSendWriteWithoutResponse peripheral: CBPeripheral
    ) {
        Task { @MainActor in
            if peripheral === rightPeripheral {
                startDrain(right: true)
            } else if peripheral === leftPeripheral {
                startDrain(right: false)
            }
        }
    }
}
