import Foundation

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
    private var recognizer: SherpaOnnxRecognizer?
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

                let nextRecognizer: SherpaOnnxRecognizer
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
                    nextRecognizer = try SherpaOnnxRecognizer(config: &config)

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
                    nextRecognizer = try SherpaOnnxRecognizer(config: &config)

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

                let result = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
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
