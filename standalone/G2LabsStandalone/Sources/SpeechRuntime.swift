import Foundation

final class SpeechRuntime {
    private let queue = DispatchQueue(label: "g2labs.speech.runtime", qos: .userInitiated)
    private weak var diagnostics: DiagnosticsStore?
    private var recognizer: SherpaOnnxRecognizer?
    private var loadedModel: SpeechModel?
    private var lastPartial = ""
    private var firstAudioAt: DispatchTime?
    var onResult: ((String, Bool) -> Void)?

    init(diagnostics: DiagnosticsStore) {
        self.diagnostics = diagnostics
    }

    func load(_ model: SpeechModel, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                let recognizer = try self.makeRecognizer(model)
                try recognizer.smokeTest(sampleRate: 16_000)
                try recognizer.recreateStream()
                if model.language != "auto" && !model.language.isEmpty {
                    try? recognizer.setOption(key: "language", value: model.language)
                }
                self.recognizer = recognizer
                self.loadedModel = model
                self.lastPartial = ""
                self.firstAudioAt = nil
                Task { @MainActor in
                    self.diagnostics?.log("stt", "Loaded + smoke-tested \(model.name) [\(model.kind.displayName)]")
                }
                completion(.success(()))
            } catch {
                Task { @MainActor in self.diagnostics?.error("stt", "Load failed: \(error.localizedDescription)") }
                completion(.failure(error))
            }
        }
    }

    func unload() {
        queue.sync {
            recognizer = nil
            loadedModel = nil
            lastPartial = ""
            firstAudioAt = nil
        }
    }

    func acceptPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard let recognizer = self.recognizer else { return }
            if self.firstAudioAt == nil { self.firstAudioAt = .now() }

            let started = DispatchTime.now()
            let floats = self.floatSamples(data)
            do {
                try recognizer.acceptWaveform(samples: floats, sampleRate: 16_000)
                var decodes = 0
                while try recognizer.isReady() {
                    try recognizer.decode()
                    decodes += 1
                }

                let result = recognizer.getResult()
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
                let audioSeconds = Double(floats.count) / 16_000.0
                let rtf = audioSeconds > 0 ? elapsed / audioSeconds : 0

                Task { @MainActor in
                    self.diagnostics?.recognizerFrames += 1
                    self.diagnostics?.decodeRtf = rtf
                }

                if recognizer.isEndpoint() {
                    if !text.isEmpty { self.emit(text, final: true) }
                    try recognizer.reset()
                    if let language = self.loadedModel?.language, language != "auto", !language.isEmpty {
                        try? recognizer.setOption(key: "language", value: language)
                    }
                    self.lastPartial = ""
                } else if !text.isEmpty && text != self.lastPartial {
                    self.lastPartial = text
                    self.emit(text, final: false)
                }

                if decodes == 0 {
                    Task { @MainActor in self.diagnostics?.log("stt", "PCM accepted; waiting for enough feature frames") }
                }
            } catch {
                Task { @MainActor in self.diagnostics?.error("stt", "Decode error: \(error.localizedDescription)") }
            }
        }
    }

    private func emit(_ text: String, final: Bool) {
        let latencyMs: Double? = firstAudioAt.map {
            Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000
        }
        Task { @MainActor in
            if final {
                self.diagnostics?.finals += 1
            } else {
                self.diagnostics?.partials += 1
                if self.diagnostics?.lastPartialLatencyMs == nil { self.diagnostics?.lastPartialLatencyMs = latencyMs }
            }
            self.diagnostics?.log(final ? "final" : "partial", text, value: latencyMs)
            self.onResult?(text, final)
        }
    }

    private func makeRecognizer(_ model: SpeechModel) throws -> SherpaOnnxRecognizer {
        let dir = model.url
        let tokens = try requiredFile(["tokens.txt"], in: dir)

        var modelConfig: SherpaOnnxOnlineModelConfig
        switch model.kind {
        case .onlineTransducer:
            var transducer = sherpaOnnxOnlineTransducerModelConfig(
                encoder: try requiredFile(["encoder.int8.onnx", "encoder.onnx"], in: dir),
                decoder: try requiredFile(["decoder.int8.onnx", "decoder.onnx"], in: dir),
                joiner: try requiredFile(["joiner.int8.onnx", "joiner.onnx"], in: dir)
            )
            modelConfig = sherpaOnnxOnlineModelConfig(tokens: tokens, transducer: transducer, numThreads: 2)
        case .onlineNemoCTC:
            var nemo = sherpaOnnxOnlineNemoCtcModelConfig(model: try requiredFile(["model.int8.onnx", "model.onnx"], in: dir))
            modelConfig = sherpaOnnxOnlineModelConfig(tokens: tokens, numThreads: 2, nemoCtc: nemo)
        case .onlineZipformerCTC:
            var ctc = sherpaOnnxOnlineZipformer2CtcModelConfig(model: try requiredFile(["model.int8.onnx", "model.onnx"], in: dir))
            modelConfig = sherpaOnnxOnlineModelConfig(tokens: tokens, zipformer2Ctc: ctc, numThreads: 2)
        case .onlineParaformer:
            var para = sherpaOnnxOnlineParaformerModelConfig(
                encoder: try requiredFile(["encoder.int8.onnx", "encoder.onnx"], in: dir),
                decoder: try requiredFile(["decoder.int8.onnx", "decoder.onnx"], in: dir)
            )
            modelConfig = sherpaOnnxOnlineModelConfig(tokens: tokens, paraformer: para, numThreads: 2)
        case .unsupportedONNX:
            throw NSError(domain: "G2LabsSpeech", code: 40, userInfo: [NSLocalizedDescriptionKey: "No speech adapter exists for this ONNX layout"])
        }

        var feature = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: feature,
            modelConfig: modelConfig,
            enableEndpoint: true,
            rule1MinTrailingSilence: 1.2,
            rule2MinTrailingSilence: 0.7,
            rule3MinUtteranceLength: 12
        )
        return try SherpaOnnxRecognizer(config: &config)
    }

    private func requiredFile(_ names: [String], in directory: URL) throws -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NSError(domain: "G2LabsSpeech", code: 41, userInfo: [NSLocalizedDescriptionKey: "Cannot enumerate model folder"])
        }
        let accepted = Set(names.map { $0.lowercased() })
        for case let url as URL in enumerator where accepted.contains(url.lastPathComponent.lowercased()) {
            return url.path
        }
        throw NSError(domain: "G2LabsSpeech", code: 42, userInfo: [NSLocalizedDescriptionKey: "Missing required file: \(names.joined(separator: " or "))"])
    }

    private func floatSamples(_ data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let lo = UInt16(base.load(fromByteOffset: i * 2, as: UInt8.self))
                let hi = UInt16(base.load(fromByteOffset: i * 2 + 1, as: UInt8.self)) << 8
                out[i] = Float(Int16(bitPattern: lo | hi)) / 32768.0
            }
        }
        return out
    }
}
