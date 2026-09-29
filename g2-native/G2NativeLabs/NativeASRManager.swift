import Foundation
import MentraBluetoothSDK

private enum SafeSherpaRecognizerError: LocalizedError {
    case native(String)

    var errorDescription: String? {
        switch self {
        case .native(let message): return message
        }
    }
}

private func safeSherpaError(_ operation: String) -> SafeSherpaRecognizerError {
    if let ptr = MentraSherpaLastError() {
        let detail = String(cString: ptr)
        if !detail.isEmpty {
            return .native("\(operation): \(detail)")
        }
    }
    return .native("\(operation) failed")
}

/// Small exception-safe wrapper around sherpa-onnx's C API.
///
/// We intentionally keep this separate from the upstream Swift convenience
/// wrapper. The C++ recognizer can throw through ONNX Runtime on malformed or
/// incompatible model execution; SherpaOnnxSafeBridge catches those exceptions
/// so G2 LABS can show an error instead of terminating the app.
private final class SafeSherpaOnlineRecognizer {
    private let recognizer: OpaquePointer
    private var stream: OpaquePointer
    private let lock = NSLock()

    init(config: UnsafePointer<SherpaOnnxOnlineRecognizerConfig>) throws {
        guard let recognizer = MentraSherpaCreateOnlineRecognizer(config) else {
            throw safeSherpaError("CreateOnlineRecognizer")
        }
        self.recognizer = recognizer

        guard let stream = MentraSherpaCreateOnlineStream(recognizer) else {
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
            throw safeSherpaError("CreateOnlineStream")
        }
        self.stream = stream
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
    }

    func setOption(key: String, value: String) throws {
        let ok = key.withCString { keyPtr in
            value.withCString { valuePtr in
                MentraSherpaOnlineStreamSetOption(stream, keyPtr, valuePtr)
            }
        }
        if ok == 0 { throw safeSherpaError("OnlineStreamSetOption") }
    }

    func acceptWaveform(samples: [Float], sampleRate: Int) throws {
        let ok = samples.withUnsafeBufferPointer { buffer in
            MentraSherpaOnlineStreamAcceptWaveform(
                stream,
                Int32(sampleRate),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        if ok == 0 { throw safeSherpaError("OnlineStreamAcceptWaveform") }
    }

    func isReady() throws -> Bool {
        var ready: Int32 = 0
        if MentraSherpaIsOnlineStreamReady(recognizer, stream, &ready) == 0 {
            throw safeSherpaError("IsOnlineStreamReady")
        }
        return ready != 0
    }

    func decode() throws {
        if MentraSherpaDecodeOnlineStream(recognizer, stream) == 0 {
            throw safeSherpaError("DecodeOnlineStream")
        }
    }

    func getResult() throws -> SherpaOnnxOnlineRecognitionResult {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else {
            throw SafeSherpaRecognizerError.native("GetOnlineStreamResult returned nil")
        }
        return SherpaOnnxOnlineRecognitionResult(result: result)
    }

    func reset() throws {
        if MentraSherpaOnlineStreamReset(recognizer, stream) == 0 {
            throw safeSherpaError("OnlineStreamReset")
        }
    }

    func recreateStream() throws {
        guard let replacement = MentraSherpaCreateOnlineStream(recognizer) else {
            throw safeSherpaError("CreateOnlineStream")
        }
        lock.lock()
        let old = stream
        stream = replacement
        lock.unlock()
        SherpaOnnxDestroyOnlineStream(old)
    }

    func isEndpoint() -> Bool {
        SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0
    }

    /// Feed staged silence until the streaming encoder is genuinely ready.
    /// Nemotron exports can use 80/160/560/1120 ms chunks, so a fixed 500 ms
    /// smoke waveform is not a valid readiness test.
    func smokeTest(sampleRate: Int = 16_000) throws {
        let chunkSamples = max(1, sampleRate / 5) // 200 ms
        let silence = [Float](repeating: 0, count: chunkSamples)
        var decodeCount = 0

        for _ in 0..<20 { // up to 4 seconds
            try acceptWaveform(samples: silence, sampleRate: sampleRate)
            while try isReady() {
                try decode()
                decodeCount += 1
            }
            if decodeCount > 0 { break }
        }

        guard decodeCount > 0 else {
            throw SafeSherpaRecognizerError.native(
                "Smoke test did not reach the encoder after 4.0 s of staged audio"
            )
        }
        try reset()
    }
}

enum NativeASRState: Equatable {
    case idle
    case loading(String)
    case ready(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "No model loaded"
        case .loading(let name): return "Loading \(name)…"
        case .ready(let name): return "Ready: \(name)"
        case .failed(let error): return "ERROR: \(error)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
final class NativeASRManager: ObservableObject {
    @Published var state: NativeASRState = .idle
    @Published var partialText = ""
    @Published var finalText = ""
    @Published var decodePasses = 0
    @Published var lastDecodeMs: Double = 0
    @Published var receivedPCMBytes: Int64 = 0

    var onTranscript: ((String, Bool) -> Void)?

    private let work = DispatchQueue(label: "com.g2labs.native.asr", qos: .userInitiated)
    private var recognizer: SafeSherpaOnlineRecognizer?
    private var generation = 0
    private var lastPartial = ""

    func unload() {
        generation += 1
        let g = generation
        state = .idle
        partialText = ""
        finalText = ""
        work.async { [weak self] in
            guard let self else { return }
            self.recognizer = nil
            self.lastPartial = ""
            _ = g
        }
    }

    func load(modelName: String, directory: URL, family: ASRFamily, language: String = "it") {
        generation += 1
        let g = generation
        state = .loading(modelName)
        partialText = ""
        finalText = ""

        work.async { [weak self] in
            guard let self else { return }
            do {
                let files = try Self.modelFiles(in: directory)
                guard let tokens = files.first(where: { $0.lastPathComponent.lowercased() == "tokens.txt" }) else {
                    throw NSError(domain: "G2NativeASR", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "tokens.txt is missing"])
                }

                let nextRecognizer: SafeSherpaOnlineRecognizer
                switch family {
                case .nemotron, .streamingTransducer:
                    guard let encoder = Self.pick(files, contains: "encoder", suffix: ".onnx"),
                          let decoder = Self.pick(files, contains: "decoder", suffix: ".onnx"),
                          let joiner = Self.pick(files, contains: "joiner", suffix: ".onnx")
                    else {
                        throw NSError(domain: "G2NativeASR", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Transducer requires encoder + decoder + joiner ONNX files"])
                    }

                    var transducer = sherpaOnnxOnlineTransducerModelConfig(
                        encoder: encoder.path,
                        decoder: decoder.path,
                        joiner: joiner.path
                    )
                    var modelConfig = sherpaOnnxOnlineModelConfig(
                        tokens: tokens.path,
                        transducer: transducer,
                        numThreads: 1,
                        provider: "cpu"
                    )
                    var feat = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
                    var config = sherpaOnnxOnlineRecognizerConfig(
                        featConfig: feat,
                        modelConfig: modelConfig,
                        enableEndpoint: true,
                        rule1MinTrailingSilence: 1.0,
                        rule2MinTrailingSilence: 0.6,
                        rule3MinUtteranceLength: 12.0
                    )
                    nextRecognizer = try SafeSherpaOnlineRecognizer(config: &config)

                case .ctc:
                    guard let model = files.first(where: {
                        let n = $0.lastPathComponent.lowercased()
                        return n.hasSuffix(".onnx") && (n.contains("ctc") || n.contains("model"))
                    }) else {
                        throw NSError(domain: "G2NativeASR", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "CTC ONNX model is missing"])
                    }

                    var nemoCtc = sherpaOnnxOnlineNemoCtcModelConfig(model: model.path)
                    var modelConfig = sherpaOnnxOnlineModelConfig(
                        tokens: tokens.path,
                        numThreads: 1,
                        provider: "cpu",
                        nemoCtc: nemoCtc
                    )
                    var feat = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
                    var config = sherpaOnnxOnlineRecognizerConfig(
                        featConfig: feat,
                        modelConfig: modelConfig,
                        enableEndpoint: true,
                        rule1MinTrailingSilence: 1.0,
                        rule2MinTrailingSilence: 0.6,
                        rule3MinUtteranceLength: 12.0
                    )
                    nextRecognizer = try SafeSherpaOnlineRecognizer(config: &config)

                default:
                    throw NSError(domain: "G2NativeASR", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "\(family.rawValue) import is recognized, but its runtime adapter is not wired yet"])
                }

                // Multilingual Nemotron's language is a per-stream option and
                // must be set before feeding the smoke-test waveform as well as
                // on the fresh live stream created afterwards.
                if family == .nemotron {
                    try nextRecognizer.setOption(key: "language", value: language)
                }

                try nextRecognizer.smokeTest(sampleRate: 16000)
                try nextRecognizer.recreateStream()

                if family == .nemotron {
                    try nextRecognizer.setOption(key: "language", value: language)
                }

                guard g == self.generation else { return }
                self.recognizer = nextRecognizer
                self.lastPartial = ""

                DispatchQueue.main.async {
                    guard g == self.generation else { return }
                    self.state = .ready(modelName)
                }
            } catch {
                guard g == self.generation else { return }
                self.recognizer = nil
                DispatchQueue.main.async {
                    guard g == self.generation else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func acceptPCM(_ pcm: Data) {
        guard state.isReady, !pcm.isEmpty else { return }
        let g = generation
        receivedPCMBytes += Int64(pcm.count)

        work.async { [weak self] in
            guard let self, g == self.generation, let recognizer = self.recognizer else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                let samples = Self.floatSamples(pcm)
                try recognizer.acceptWaveform(samples: samples, sampleRate: 16000)
                var passes = 0
                while try recognizer.isReady() {
                    try recognizer.decode()
                    passes += 1
                }

                let result = try recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

                if recognizer.isEndpoint() {
                    if !result.isEmpty {
                        DispatchQueue.main.async {
                            self.finalText = result
                            self.partialText = ""
                            self.onTranscript?(result, true)
                        }
                    }
                    try recognizer.reset()
                    if case .ready = self.state {
                        // Set language again on the freshly reset stream for Nemotron.
                        try? recognizer.setOption(key: "language", value: "it-IT")
                    }
                    self.lastPartial = ""
                } else if !result.isEmpty && result != self.lastPartial {
                    self.lastPartial = result
                    DispatchQueue.main.async {
                        self.partialText = result
                        self.onTranscript?(result, false)
                    }
                }

                if passes > 0 {
                    DispatchQueue.main.async {
                        self.decodePasses += passes
                        self.lastDecodeMs = elapsed
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static func modelFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result
    }

    private static func pick(_ files: [URL], contains token: String, suffix: String) -> URL? {
        let matches = files.filter {
            let n = $0.lastPathComponent.lowercased()
            return n.contains(token) && n.hasSuffix(suffix)
        }
        return matches.sorted {
            let a = $0.lastPathComponent.lowercased()
            let b = $1.lastPathComponent.lowercased()
            if a.contains("int8") != b.contains("int8") { return a.contains("int8") }
            return a < b
        }.first
    }

    private static func floatSamples(_ pcm: Data) -> [Float] {
        let count = pcm.count / MemoryLayout<Int16>.size
        return pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            let ptr = base.bindMemory(to: Int16.self, capacity: count)
            return (0..<count).map { Float(Int16(littleEndian: ptr[$0])) / 32768.0 }
        }
    }
}
