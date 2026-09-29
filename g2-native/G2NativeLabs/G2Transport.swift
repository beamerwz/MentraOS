import Foundation
import MentraBluetoothSDK

struct G2PairCandidate: Identifiable, Equatable {
    let serial: String
    let leftName: String?
    let rightName: String?

    var id: String { serial }

    // The real Mentra SDK owns the L/R discovery and only exposes a G2 after
    // its own discovery logic has identified a connectable device.
    var complete: Bool { true }
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
        case .waitingForBoth: return "Preparing G2"
        case .connecting: return "Connecting"
        case .authenticating: return "Starting Mentra session"
        case .ready: return "G2 ready"
        case .failed: return "Connection problem"
        }
    }

    var detail: String {
        switch self {
        case .bluetoothOff:
            return "Turn Bluetooth on to continue."
        case .scanning:
            return "Using Mentra Bluetooth SDK to discover your G2."
        case .waitingForBoth(let serial):
            return "Mentra is preparing both lenses for \(serial)."
        case .connecting(let serial):
            return "Mentra is connecting \(serial)…"
        case .authenticating(let serial):
            return "Mentra is authenticating and starting the G2 runtime for \(serial)…"
        case .ready(let serial):
            return "\(serial) is connected through Mentra Bluetooth SDK."
        case .failed(let message):
            return message
        }
    }
}

@MainActor
final class G2Transport: NSObject, ObservableObject {
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

    private let sdk = MentraBluetoothSDK()
    private var scanSession: ScanSession?
    private var discovered: [String: Device] = [:]
    private var selectedDeviceKey: String?

    private var bootstrapTask: Task<Void, Never>?
    private var captionTask: Task<Void, Never>?
    private var lastCaption = ""
    private var lastCaptionAt = Date.distantPast

    override init() {
        super.init()

        sdk.delegate = self

        asr.onTranscript = { [weak self] text, final in
            guard let self else { return }
            self.displayCaption(text, isFinal: final)
        }

        bootstrapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            self?.bootstrapMentra()
        }
    }

    deinit {
        bootstrapTask?.cancel()
        captionTask?.cancel()
        scanSession?.stop()
        sdk.invalidate()
    }

    // MARK: - Actual Mentra Bluetooth SDK

    private func bootstrapMentra() {
        if sdk.glasses.connected {
            adoptMentraState(sdk.glasses)
            armMentraMic(reason: "existing Mentra session")
            return
        }

        if sdk.defaultDevice != nil {
            do {
                pairingStage = .connecting(sdk.defaultDevice?.name ?? "G2")
                bluetoothState = "On"
                try sdk.connectDefault()
                log("Mentra SDK connectDefault()")
                return
            } catch {
                log("Mentra default reconnect deferred: \(error.localizedDescription)")
            }
        }

        scan()
    }

    func scan() {
        scanSession?.stop()
        scanSession = nil
        candidates.removeAll()
        discovered.removeAll()

        pairingStage = .scanning

        do {
            scanSession = try sdk.scan(
                model: .g2,
                timeout: 15,
                onResults: { [weak self] devices in
                    guard let self else { return }
                    self.consumeMentraScan(devices)
                },
                onComplete: { [weak self] devices in
                    guard let self else { return }
                    self.consumeMentraScan(devices)
                    if self.candidates.isEmpty && !self.isReady {
                        self.log("Mentra scan completed with no G2 found")
                    }
                }
            )
            bluetoothState = "On"
            log("Mentra SDK G2 scan started")
        } catch let error as BluetoothSdkError {
            handleSdkError(error)
            scheduleBootstrapRetry()
        } catch {
            lastError = error.localizedDescription
            pairingStage = .failed(error.localizedDescription)
            log("Mentra scan error: \(error.localizedDescription)")
            scheduleBootstrapRetry()
        }
    }

    private func scheduleBootstrapRetry() {
        bootstrapTask?.cancel()
        bootstrapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !self.isReady else { return }
            self.bootstrapMentra()
        }
    }

    private func consumeMentraScan(_ devices: [Device]) {
        for device in devices where device.model == .g2 {
            let key = device.name.isEmpty ? device.id : device.name
            discovered[key] = device
        }

        candidates = discovered
            .map { key, device in
                G2PairCandidate(
                    serial: key,
                    leftName: device.name,
                    rightName: device.name
                )
            }
            .sorted { $0.serial < $1.serial }
    }

    func pair(serial: String) {
        guard let device = discovered[serial] else {
            pairingStage = .failed("Mentra no longer has that G2 in the current scan.")
            return
        }

        selectedDeviceKey = serial
        scanSession?.stop()
        scanSession = nil
        pairingStage = .connecting(serial)
        lastError = nil

        do {
            try sdk.connect(
                to: device,
                options: ConnectOptions(
                    saveAsDefault: true,
                    cancelExistingConnectionAttempt: true
                )
            )
            log("Mentra SDK connecting to \(serial)")
        } catch let error as BluetoothSdkError {
            handleSdkError(error)
        } catch {
            lastError = error.localizedDescription
            pairingStage = .failed(error.localizedDescription)
            log("Mentra connect error: \(error.localizedDescription)")
        }
    }

    func forgetAndRescan() {
        scanSession?.stop()
        scanSession = nil

        sdk.setMicState(
            enabled: false,
            useGlassesMic: true,
            sendTranscript: false,
            sendLc3Data: false
        )
        sdk.disconnect()
        sdk.forget()
        sdk.clearDefaultDevice()

        discovered.removeAll()
        candidates.removeAll()
        selectedDeviceKey = nil

        connectedName = nil
        connectedSerial = nil
        micArmed = false

        audioPackets = 0
        audioBytes = 0
        pcmChunks = 0
        pcmBytes = 0
        pcmRMS = 0
        lastAudioAt = nil

        pairingStage = .scanning
        log("Mentra SDK forgot G2")

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.scan()
        }
    }

    private func armMentraMic(reason: String) {
        guard sdk.glasses.connected else {
            micArmed = false
            return
        }

        // This is the exact SDK path Mentra uses. DeviceManager/G2 now own
        // EvenHub page lifecycle, mic restart, BLE pacing and reconnection.
        sdk.setMicState(
            enabled: true,
            useGlassesMic: true,
            sendTranscript: false,
            sendLc3Data: false
        )

        micArmed = true
        log("Mentra SDK mic enabled (\(reason))")
    }

    func ensureRuntimeAlive(reason: String) {
        if sdk.glasses.connected {
            adoptMentraState(sdk.glasses)
            armMentraMic(reason: reason)
            return
        }

        micArmed = false
        do {
            try sdk.connectDefault()
            log("Mentra SDK reconnect requested (\(reason))")
        } catch {
            log("Mentra reconnect unavailable: \(error.localizedDescription)")
            scheduleBootstrapRetry()
        }
    }

    func applicationDidBecomeActive() {
        ensureRuntimeAlive(reason: "app became active")
    }

    private func adoptMentraState(_ glasses: GlassesRuntimeState) {
        guard glasses.connected else {
            if !isReady {
                connectedName = nil
                connectedSerial = nil
                micArmed = false
            }
            return
        }

        bluetoothState = "On"

        let device = glasses.device
        let serial =
            device?.serialNumber
            ?? selectedDeviceKey
            ?? sdk.defaultDevice?.name
            ?? "Even G2"

        connectedSerial = serial
        connectedName =
            device?.bluetoothName
            ?? sdk.defaultDevice?.name
            ?? "Even G2"

        if glasses.ready {
            if !isReady {
                log("Mentra SDK reports G2 fully booted")
            }
            pairingStage = .ready(serial)
        } else {
            pairingStage = .authenticating(serial)
        }
    }

    // MARK: - Offline ASR stays ours

    func activateModel(_ model: ASRModel, directory: URL) {
        log("Loading ASR model: \(model.name) [\(model.family.rawValue)]")

        // Bluetooth is deliberately untouched here. Mentra SDK owns the live
        // glasses transport on its own lifecycle while ORT initializes.
        asr.load(
            modelName: model.name,
            directory: directory,
            family: model.family,
            language: "it-IT"
        )
    }

    private func displayCaption(_ text: String, isFinal: Bool) {
        guard !text.isEmpty, sdk.glasses.connected else { return }

        let now = Date()
        if !isFinal,
           text == lastCaption,
           now.timeIntervalSince(lastCaptionAt) < 0.12 {
            return
        }

        lastCaption = text
        lastCaptionAt = now
        captionUpdates += 1
        log("\(isFinal ? "FINAL" : "PARTIAL"): \(text.prefix(90))")

        captionTask?.cancel()
        captionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sdk.displayText(text)
            } catch {
                self.lastError = error.localizedDescription
                self.log("Mentra displayText error: \(error.localizedDescription)")
            }
        }
    }

    private func acceptMentraPcm(_ event: MicPcmEvent) {
        let pcm = event.pcm
        guard !pcm.isEmpty else { return }

        // With the SDK path, a delivered PCM event is our authoritative proof
        // that the G2 mic session is alive.
        audioPackets += 1
        audioBytes += pcm.count
        lastAudioAt = Date()

        pcmChunks += 1
        pcmBytes += Int64(pcm.count)
        pcmRMS = Self.rms(ofPCM16LE: pcm)

        if !micArmed {
            micArmed = true
        }

        asr.acceptPCM(pcm)
    }

    private static func rms(ofPCM16LE data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }

        let meanSquare: Double = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            let samples = base.bindMemory(to: Int16.self, capacity: count)
            var sum = 0.0

            for index in 0..<count {
                let value = Double(Int16(littleEndian: samples[index])) / 32768.0
                sum += value * value
            }

            return sum / Double(count)
        }

        return sqrt(meanSquare)
    }

    private func handleSdkError(_ error: BluetoothSdkError) {
        lastError = error.description
        log("Mentra SDK error: \(error.description)")

        switch error.code {
        case "bluetooth_powered_off":
            bluetoothState = "Off"
            pairingStage = .bluetoothOff
        case "bluetooth_unauthorized":
            bluetoothState = "Unauthorized"
            pairingStage = .failed(error.message)
        case "bluetooth_not_ready":
            bluetoothState = "Starting"
        default:
            pairingStage = .failed(error.message)
        }
    }

    private func log(_ text: String) {
        events.insert(
            "\(Date().formatted(date: .omitted, time: .standard))  \(text)",
            at: 0
        )
        if events.count > 200 {
            events.removeLast(events.count - 200)
        }
    }
}

// MARK: - MentraBluetoothSDKDelegate

extension G2Transport: MentraBluetoothSDKDelegate {
    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didUpdate state: MentraBluetoothState
    ) {
        adoptMentraState(state.glasses)
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didUpdateGlasses glasses: GlassesRuntimeState
    ) {
        let wasReady = isReady
        adoptMentraState(glasses)

        if glasses.connected && glasses.ready {
            if !wasReady {
                armMentraMic(reason: "Mentra G2 became ready")
            }
        } else if !glasses.connected {
            micArmed = false
            if wasReady {
                log("Mentra SDK reports G2 disconnected; waiting for SDK reconnect")
            }
        }
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didUpdateSdkState sdkState: PhoneSdkRuntimeState
    ) {
        if sdkState.searching {
            bluetoothState = "On"
            if !isReady { pairingStage = .scanning }
        }
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didUpdateScan scan: BluetoothScanState
    ) {
        consumeMentraScan(scan.devices)
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didDiscover device: Device
    ) {
        guard device.model == .g2 else { return }
        consumeMentraScan(Array(discovered.values) + [device])
        log("Mentra discovered G2: \(device.name)")
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didStopScan reason: ScanStopReason
    ) {
        if !isReady {
            log("Mentra scan stopped: \(String(describing: reason))")
        }
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didReceive event: BluetoothEvent
    ) {
        controlPackets += 1

        switch event {
        case .micHealth(let health):
            log("Mentra mic health: gaps=\(health.sequenceGapEvents) decodeFailures=\(health.decodeFailures)")
        case .raw(let name, _):
            if name == "pairing_info" || name == "entering_pairing_mode" || name == "owner_replaced" {
                log("Mentra event: \(name)")
            }
        default:
            break
        }
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didReceiveMicPcm event: MicPcmEvent
    ) {
        acceptMentraPcm(event)
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didReceiveMicLc3 event: MicLc3Event
    ) {
        // We deliberately request PCM from Mentra so its proven G2 LC3 decoder
        // and microphone lifecycle remain the single audio path.
        audioBytes += event.lc3.count
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didChangeDefaultDevice device: Device?
    ) {
        if let device {
            log("Mentra default G2: \(device.name)")
        }
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didLog message: String
    ) {
        log("Mentra: \(message)")
    }

    func mentraBluetoothSDK(
        _ sdk: MentraBluetoothSDK,
        didFail error: BluetoothSdkError
    ) {
        handleSdkError(error)
    }
}
