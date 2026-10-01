import Foundation
#if canImport(whisper)
import whisper
#endif

final class WhisperCppTranscriber: LocalSTTTranscriber, @unchecked Sendable {
    let runtimeId = "whisper.cpp"

    private static let sampleRate = 16_000
    private static let stepSamples = 8_000
    private static let windowSamples = 80_000
    private static let threads = 4

    private let worker = DispatchQueue(label: "com.mentra.g2labs.whispercpp", qos: .userInteractive)
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var rolling: [Float] = []
    private var samplesSinceDecode = 0
    private var running = false
    private var initializing = false
    private var creationAttempted = false
    private var lastText = ""

    var canInitializeSelectedModelInProcess: Bool {
        lock.lock(); defer { lock.unlock() }
        return !running && !initializing && !creationAttempted && context == nil
    }

    var hasActiveRecognizer: Bool {
        lock.lock(); defer { lock.unlock() }
        return running && context != nil
    }

    @discardableResult
    func initialize() -> Bool {
#if canImport(whisper)
        lock.lock()
        if running { lock.unlock(); return true }
        if initializing { lock.unlock(); return false }
        initializing = true
        creationAttempted = true
        lock.unlock()
        defer { lock.lock(); initializing = false; lock.unlock() }

        guard let directory = STTTools.modelPathForRecognizer(),
              let model = STTTools.whisperCppModelFile(in: directory)
        else {
            G2LabDiagnostics.markError("whisper.cpp selected but no GGML .bin model was found")
            return false
        }

        G2LabDiagnostics.markModel(state: "initializing", path: directory)
        var params = whisper_context_default_params()
        params.flash_attn = true
        guard let loaded = whisper_init_from_file_with_params(model, params) else {
            G2LabDiagnostics.markError("whisper.cpp could not load the selected GGML model")
            G2LabDiagnostics.markModel(state: "failed", path: directory)
            return false
        }

        lock.lock()
        context = loaded
        running = true
        rolling.removeAll(keepingCapacity: true)
        samplesSinceDecode = 0
        lastText = ""
        lock.unlock()

        STTTools.markCurrentModelReady()
        G2LabDiagnostics.markModel(state: "ready", path: directory)
        Bridge.log("G2LAB whisper.cpp runtime ready: \(model)")
        return true
#else
        G2LabDiagnostics.markError("whisper.cpp framework is not bundled in this IPA")
        return false
#endif
    }

    func acceptAudio(pcm16le: Data) {
        lock.lock()
        let active = running && context != nil
        lock.unlock()
        guard active else { return }

        let converted = Self.floatSamples(from: pcm16le)
        guard !converted.isEmpty else { return }

        worker.async { [weak self] in
            guard let self else { return }
            self.rolling.append(contentsOf: converted)
            if self.rolling.count > Self.windowSamples {
                self.rolling.removeFirst(self.rolling.count - Self.windowSamples)
            }
            self.samplesSinceDecode += converted.count
            guard self.samplesSinceDecode >= Self.stepSamples else { return }
            self.samplesSinceDecode = 0
            self.decodeWindow()
        }
    }

    private func decodeWindow() {
#if canImport(whisper)
        lock.lock()
        guard running, let context else { lock.unlock(); return }
        lock.unlock()
        guard rolling.count >= Self.sampleRate else { return }

        let started = DispatchTime.now().uptimeNanoseconds
        let audioMs = Double(rolling.count) * 1000.0 / Double(Self.sampleRate)
        let language = STTTools.languageForRecognizer()?.split(separator: "-").first.map(String.init) ?? "it"
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(Self.threads)
        params.translate = false
        params.no_context = false
        params.no_timestamps = true
        params.single_segment = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.max_tokens = 48
        params.audio_ctx = 768
        params.temperature_inc = -1.0

        var rc: Int32 = -1
        language.withCString { lang in
            params.language = lang
            rc = rolling.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        let decodeMs = Double(ended - started) / 1_000_000.0
        G2LabDiagnostics.markDecodeBatch(ns: ended, passes: 1, decodeMs: decodeMs, audioMs: audioMs)

        guard rc == 0 else {
            G2LabDiagnostics.markError("whisper.cpp decode failed with code \(rc)")
            return
        }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            text += String(cString: whisper_full_get_segment_text(context, i))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastText else { return }
        lastText = text
        G2LabDiagnostics.markPartial(ns: ended, decodeMs: decodeMs, audioMs: audioMs)
        G2LabDiagnostics.markTranscript(ns: ended)
        STTTools.didReceivePartialTranscription(text)
#endif
    }

    func shutdown() {
        lock.lock()
        running = false
        let old = context
        context = nil
        lock.unlock()
        worker.sync {
            rolling.removeAll()
            samplesSinceDecode = 0
            lastText = ""
        }
#if canImport(whisper)
        if let old { whisper_free(old) }
#endif
    }

    deinit { shutdown() }

    private static func floatSamples(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var output = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<min(count, src.count) {
                output[i] = Float(Int16(littleEndian: src[i])) / 32768.0
            }
        }
        return output
    }
}
