import Foundation
import MentraBluetoothSDK

struct G2PairCandidate: Identifiable, Equatable {
    let serial: String
    let displayName: String
    var id: String { serial }
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
        case .authenticating: return "Authenticating G2"
        case .ready: return "G2 ready"
        case .failed: return "Pairing problem"
        }
    }

    var detail: String {
        switch self {
        case .bluetoothOff:
            return "Turn Bluetooth on to continue."
        case .scanning:
            return "Mentra Bluetooth is scanning for your Even G2."
        case .waitingForBoth(let id):
            return "Mentra found \(id) and is preparing the pair."
        case .connecting(let id):
            return "Mentra Bluetooth is connecting \(id)…"
        case .authenticating(let id):
            return "Mentra is authenticating both lenses and restoring the EvenHub session for \(id)…"
        case .ready(let id):
            return "\(id) is connected through Mentra Bluetooth."
        case .failed(let message):
            return message
        }
    }
}

@MainActor
final class G2Transport: NSObject, ObservableObject {
    @Published var bluetoothState = "Mentra SDK starting"
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

    private let sdk: MentraBluetoothSDK
    private var scanSession: ScanSession?
    private var devicesByLabel: [String: Device] = [:]
    private var selectedLabel: String?
    private var runtimeStarted = false
    private var modelWatchTask: Task<Void, Never>?

    override init() {
        let client = MentraBluetoothSDK()
        sdk = client
        super.init()

        client.delegate = self

        asr.onTranscript = { [weak self] text, final in
            guard let self else { return }
            Task { @MainActor in
                self.displayCaption(text, isFinal: final)
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            self?.restoreOrScan()
        }
    }

    deinit {
        scanSession?.cancel()
        modelWatchTask?.cancel()
    }

    func scan() {
        scanSession?.cancel()
        scanSession = nil
        devicesByLabel.removeAll()
        candidates.removeAll()
        lastError = nil
        bluetoothState = "Mentra SDK scanning"
        pairingStage = .scanning

        do {
            scanSession = try sdk.scan(
                model: .g2,
                timeout: 15,
                onResults: { [weak self] devices in
                    guard let self else { return }
                    self.consumeScanResults(devices)
                },
                onComplete: { [weak self] devices in
                    guard let self else { return }
                    self.consumeScanResults(devices)
                    if devices.isEmpty, !self.isReady {
                        self.log("Mentra scan completed with no G2 result")
                    }
                }
            )
            log("Mentra G2 scan started")
        } catch {
            let message = error.localizedDescription
            lastError = message
            if message.localizedCaseInsensitiveContains("bluetooth") {
                bluetoothState = "Unavailable"
                pairingStage = .bluetoothOff
            } else {
                pairingStage = .failed(message)
            }
            log("Mentra scan error: \(message)")
        }
    }

    func pair(serial: String) {
        guard let device = devicesByLabel[serial] else {
            selectedLabel = serial
            pairingStage = .waitingForBoth(serial)
            scan()
            return
        }

        selectedLabel = serial
        lastError = nil
        scanSession?.cancel()
        scanSession = nil
        pairingStage = .connecting(serial)
        bluetoothState = "Mentra SDK connecting"
        log("Mentra connect: \(device.name)")

        do {
            try sdk.connect(
                to: device,
                options: ConnectOptions(
                    saveAsDefault: true,
                    cancelExistingConnectionAttempt: true,
                    requiresAncs: false
                )
            )
        } catch {
            let message = error.localizedDescription
            lastError = message
            pairingStage = .failed(message)
            log("Mentra connect error: \(message)")
        }
    }

    func forgetAndRescan() {
        modelWatchTask?.cancel()
        modelWatchTask = nil
        sdk.setMicState(
            enabled: false,
            useGlassesMic: true,
            sendTranscript: false,
            sendLc3Data: false
        )
        sdk.forget()
        asr.unload()

        runtimeStarted = false
        micArmed = false
        connectedName = nil
        connectedSerial = nil
        selectedLabel = nil
        lastAudioAt = nil
        audioPackets = 0
        audioBytes = 0
        pcmChunks = 0
        pcmBytes = 0
        pcmRMS = 0

        log("Mentra connection forgotten")
        scan()
    }

    func ensureRuntimeAlive(reason: String) {
        guard isReady else { return }

        let staleAudio: Bool
        if let lastAudioAt {
            staleAudio = Date().timeIntervalSince(lastAudioAt) > 2.0
        } else {
            staleAudio = true
        }

        log("Mentra runtime check: \(reason) • staleAudio=\(staleAudio)")

        // Do not hand-roll an EvenHub OFF/ON edge here. Re-enabling through the
        // Mentra SDK enters its G2 restartMic/rebuildPage recovery path, which
        // owns page liveness, mic intent, heartbeats and both-lens recovery.
        if !micArmed || staleAudio {
            sdk.setMicState(
                enabled: true,
                useGlassesMic: true,
                sendTranscript: false,
                sendLc3Data: true
            )
            micArmed = true
            log(staleAudio ? "Mentra requested G2 mic/session recovery" : "Mentra G2 mic enabled")
        }
    }

    func applicationDidBecomeActive() {
        ensureRuntimeAlive(reason: "app returned active")
    }

    func activateModel(_ model: ASRModel, directory: URL) {
        ensureRuntimeAlive(reason: "before ASR model load")
        log("Loading ASR model: \(model.name) [\(model.family.rawValue)]")

        asr.load(
            modelName: model.name,
            directory: directory,
            family: model.family,
            language: "it-IT"
        )

        modelWatchTask?.cancel()
        modelWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.writeGlassesText("Loading \(model.name)…")

            var ticks = 0
            while case .loading = self.asr.state, ticks < 240, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                ticks += 1
            }
            guard !Task.isCancelled else { return }

            self.ensureRuntimeAlive(reason: "ASR model load finished")

            if self.asr.state.isReady {
                await self.writeGlassesText("Listening…")
            } else if case .failed(let message) = self.asr.state {
                await self.writeGlassesText("ASR error\n\(String(message.prefix(72)))")
            }
        }
    }

    private func restoreOrScan() {
        if let device = sdk.defaultDevice, device.model == .g2 {
            selectedLabel = label(for: device)
            bluetoothState = "Mentra SDK reconnecting"
            pairingStage = .connecting(selectedLabel ?? device.name)
            log("Mentra default G2 found; attempting reconnect")
            do {
                try sdk.connectDefault(
                    options: ConnectOptions(
                        saveAsDefault: true,
                        cancelExistingConnectionAttempt: true,
                        requiresAncs: false
                    )
                )
            } catch {
                log("Mentra default reconnect deferred: \(error.localizedDescription)")
                scan()
            }
        } else {
            scan()
        }
    }

    private func consumeScanResults(_ devices: [Device]) {
        for device in devices where device.model == .g2 {
            let key = label(for: device)
            devicesByLabel[key] = device
        }
        candidates = devicesByLabel
            .map { key, device in G2PairCandidate(serial: key, displayName: device.name) }
            .sorted { $0.serial.localizedCaseInsensitiveCompare($1.serial) == .orderedAscending }
    }

    private func label(for device: Device) -> String {
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? device.id : name
    }

    private func startRuntimeSession() {
        guard !runtimeStarted else {
            ensureRuntimeAlive(reason: "Mentra state refreshed")
            return
        }
        runtimeStarted = true

        sdk.setMicState(
            enabled: true,
            useGlassesMic: true,
            sendTranscript: false,
            sendLc3Data: true
        )
        micArmed = true
        log("Mentra owns G2 mic + EvenHub lifecycle")

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.writeGlassesText(
                self.asr.state.isReady
                    ? "Listening…"
                    : "G2 LABS\nImport + activate a model"
            )
        }
    }

    private func displayCaption(_ text: String, isFinal: Bool) {
        guard !text.isEmpty, isReady else { return }
        captionUpdates += 1
        log("\(isFinal ? "FINAL" : "PARTIAL"): \(text.prefix(90))")

        Task { @MainActor [weak self] in
            await self?.writeGlassesText(text)
        }
    }

    private func writeGlassesText(_ text: String) async {
        do {
            try await sdk.displayText(text, x: 0, y: 0, size: 24)
        } catch {
            let message = error.localizedDescription
            lastError = message
            log("Mentra display error: \(message)")
        }
    }

    private func handlePcm(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        pcmChunks += 1
        pcmBytes += Int64(pcm.count)
        pcmRMS = Self.rms(ofPCM16LE: pcm)
        lastAudioAt = Date()
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
        if events.count > 180 {
            events.removeLast(events.count - 180)
        }
    }
}

extension G2Transport: MentraBluetoothSDKDelegate {
    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didUpdate state: MentraBluetoothState) {
        bluetoothState = state.glasses.connected ? "Mentra SDK connected" : "Mentra SDK ready"
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didUpdateGlasses glasses: GlassesRuntimeState) {
        if glasses.connected {
            let device = glasses.device
            let identifier =
                device?.serialNumber
                ?? selectedLabel
                ?? device?.bluetoothName
                ?? "Even G2"

            connectedSerial = device?.serialNumber ?? selectedLabel
            connectedName = device?.bluetoothName ?? "Even G2"
            bluetoothState = "Mentra SDK connected"

            if glasses.ready {
                pairingStage = .ready(identifier)
                startRuntimeSession()
            } else {
                pairingStage = .authenticating(identifier)
            }
        } else {
            let prior = connectedSerial ?? selectedLabel
            connectedName = nil
            connectedSerial = nil
            runtimeStarted = false
            micArmed = false
            bluetoothState = "Mentra SDK reconnecting"

            if let prior {
                pairingStage = .connecting(prior)
                log("Mentra reports G2 temporarily disconnected; SDK recovery remains active")
            } else {
                pairingStage = .scanning
            }
        }
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didUpdateSdkState sdkState: PhoneSdkRuntimeState) {
        if sdkState.searching {
            bluetoothState = "Mentra SDK scanning"
        }
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didUpdateScan scan: BluetoothScanState) {
        consumeScanResults(scan.devices.filter { $0.model == .g2 })
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didDiscover device: Device) {
        guard device.model == .g2 else { return }
        let key = label(for: device)
        devicesByLabel[key] = device
        consumeScanResults(Array(devicesByLabel.values))
        log("Mentra discovered G2: \(device.name)")
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didStopScan reason: ScanStopReason) {
        log("Mentra scan stopped: \(reason)")
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didReceive event: BluetoothEvent) {
        controlPackets += 1
        if case .micHealth(let health) = event {
            log("Mentra mic health: \(health.description)")
        }
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didReceiveMicPcm event: MicPcmEvent) {
        handlePcm(event.pcm)
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didReceiveMicLc3 event: MicLc3Event) {
        guard !event.lc3.isEmpty else { return }
        audioPackets += 1
        audioBytes += event.lc3.count
        lastAudioAt = Date()
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didChangeDefaultDevice device: Device?) {
        guard let device, device.model == .g2 else { return }
        selectedLabel = label(for: device)
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didLog message: String) {
        // Keep useful Mentra lifecycle messages while avoiding thousands of noisy
        // audio/debug lines in the in-app diagnostics list.
        let lower = message.lowercased()
        if lower.contains("g2:")
            || lower.contains("mic")
            || lower.contains("pair")
            || lower.contains("connect")
            || lower.contains("recover")
            || lower.contains("heartbeat")
        {
            log("MENTRA • \(message)")
        }
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didFail error: BluetoothSdkError) {
        lastError = error.message
        if error.code.localizedCaseInsensitiveContains("bluetooth") {
            bluetoothState = "Unavailable"
            pairingStage = .bluetoothOff
        } else {
            log("Mentra SDK error [\(error.code)]: \(error.message)")
        }
    }
}
