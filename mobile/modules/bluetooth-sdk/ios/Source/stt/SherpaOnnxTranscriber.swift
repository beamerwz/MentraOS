import Foundation
import UIKit

/// Persistent, process-lifetime diagnostics for G2 LABS.
/// The Model Lab polls this snapshot even after a Captions session has been opened/closed,
/// so a dead pipeline can be localized without needing Xcode logs.
final class G2LabDiagnostics {
    private static let lock = NSLock()

    private static var lastLc3Ms: Double = -1
    private static var lastPcmMs: Double = -1
    private static var lastIngestMs: Double = -1
    private static var lastDecodeMs: Double = -1
    private static var lastTranscriptMs: Double = -1
    private static var lastBridgeMs: Double = -1
    private static var lastDisplayMs: Double = -1

    private static var firstIngestMs: Double = -1
    private static var firstPartialLatencyMs: Double = -1
    private static var previousPartialMs: Double = -1
    private static var partialIntervalMs: Double = -1
    private static var partialTimesMs: [Double] = []
    private static var decodeRtf: Double = -1
    private static var decodePasses: Int = 0
    private static var endpointCount: Int = 0
    private static var queueDropCount: Int = 0
    private static var lc3SequenceGapCount: Int = 0
    private static var lc3DecodeFailureCount: Int = 0
    private static var backgroundGlassesKeepaliveCount: Int = 0
    private static var backgroundAudioKeepaliveActive = false
    private static var backgroundAudioKeepaliveStarts: Int = 0
    private static var longestPartialGapMs: Double = -1
    private static var lastEndpointMs: Double = -1
    private static var audioBacklogMs: Double = -1
    private static var sttToDisplayMs: Double = -1

    // Speech-onset-aware latency. Unlike firstIngestMs, these exclude idle
    // silence before somebody actually starts speaking.
    private static var speechActive = false
    private static var lastSpeechOnsetMs: Double = -1
    private static var speechToFirstPartialMs: Double = -1
    private static var speechToDisplayMs: Double = -1
    private static var speechUtteranceCount: Int = 0
    private static var awaitingSpeechPartial = false
    private static var awaitingSpeechDisplay = false
    private static var firstSpeechPartialEventMs: Double = -1
    private static let maxValidSpeechLatencySampleMs: Double = 3_000
    private static var previousSpeechPartialMs: Double = -1
    private static var longestSpeechPartialGapMs: Double = -1

    private static var modelState = "no-model"
    private static var modelPath = ""
    private static var lastError = ""

    private static func nowMs(_ ns: UInt64? = nil) -> Double {
        Double(ns ?? DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
    }

    private static func age(_ timestampMs: Double, now: Double) -> Double {
        timestampMs < 0 ? -1 : max(0, now - timestampMs)
    }

    static func resetPipeline() {
        lock.lock()
        defer { lock.unlock() }
        lastLc3Ms = -1
        lastPcmMs = -1
        lastIngestMs = -1
        lastDecodeMs = -1
        lastTranscriptMs = -1
        lastBridgeMs = -1
        lastDisplayMs = -1
        firstIngestMs = -1
        firstPartialLatencyMs = -1
        previousPartialMs = -1
        partialIntervalMs = -1
        partialTimesMs.removeAll(keepingCapacity: true)
        decodeRtf = -1
        decodePasses = 0
        endpointCount = 0
        queueDropCount = 0
        lc3SequenceGapCount = 0
        lc3DecodeFailureCount = 0
        backgroundGlassesKeepaliveCount = 0
        backgroundAudioKeepaliveActive = false
        backgroundAudioKeepaliveStarts = 0
        longestPartialGapMs = -1
        lastEndpointMs = -1
        audioBacklogMs = -1
        sttToDisplayMs = -1
        speechActive = false
        lastSpeechOnsetMs = -1
        speechToFirstPartialMs = -1
        speechToDisplayMs = -1
        speechUtteranceCount = 0
        awaitingSpeechPartial = false
        awaitingSpeechDisplay = false
        firstSpeechPartialEventMs = -1
        previousSpeechPartialMs = -1
        longestSpeechPartialGapMs = -1
        lastError = ""
    }

    static func markModel(state: String, path: String? = nil) {
        lock.lock()
        modelState = state
        if let path { modelPath = path }
        lock.unlock()
    }

    static func markError(_ message: String) {
        lock.lock()
        lastError = message
        lock.unlock()
    }

    static func markLc3(ns: UInt64) {
        lock.lock()
        lastLc3Ms = nowMs(ns)
        lock.unlock()
    }

    static func markPcm(ns: UInt64) {
        lock.lock()
        lastPcmMs = nowMs(ns)
        lock.unlock()
    }

    static func markIngest(ns: UInt64) {
        let t = nowMs(ns)
        lock.lock()
        lastIngestMs = t
        if firstIngestMs < 0 { firstIngestMs = t }
        lock.unlock()
    }

    static func markQueue(depth: Int, audioMs: Double) {
        lock.lock()
        audioBacklogMs = Double(max(0, depth)) * max(0, audioMs)
        lock.unlock()
    }

    static func markDecodeBatch(ns: UInt64, passes: Int, decodeMs: Double, audioMs: Double) {
        lock.lock()
        lastDecodeMs = nowMs(ns)
        decodePasses += max(0, passes)
        if audioMs > 0 {
            decodeRtf = max(0, decodeMs / audioMs)
        }
        lock.unlock()
    }

    static func markPartial(ns: UInt64, decodeMs: Double, audioMs: Double) {
        let t = nowMs(ns)
        lock.lock()
        if firstPartialLatencyMs < 0, firstIngestMs >= 0 {
            firstPartialLatencyMs = max(0, t - firstIngestMs)
        }
        if previousPartialMs >= 0 {
            partialIntervalMs = max(0, t - previousPartialMs)
            longestPartialGapMs = max(longestPartialGapMs, partialIntervalMs)
        }
        previousPartialMs = t

        if awaitingSpeechPartial, lastSpeechOnsetMs >= 0, t >= lastSpeechOnsetMs {
            let delta = t - lastSpeechOnsetMs
            awaitingSpeechPartial = false

            // A several-second "speech latency" sample is a false energy-onset
            // association (room noise / TV / stale speech state), not a useful
            // latency measurement. Only arm display timing after a plausible,
            // matched first partial from the same detected speech run.
            if delta <= maxValidSpeechLatencySampleMs {
                speechToFirstPartialMs = delta
                firstSpeechPartialEventMs = t
                awaitingSpeechDisplay = true
            } else {
                speechToFirstPartialMs = -1
                speechToDisplayMs = -1
                firstSpeechPartialEventMs = -1
                awaitingSpeechDisplay = false
            }
        }
        if speechActive {
            if previousSpeechPartialMs >= 0 {
                longestSpeechPartialGapMs = max(
                    longestSpeechPartialGapMs,
                    t - previousSpeechPartialMs
                )
            }
            previousSpeechPartialMs = t
        }

        partialTimesMs.append(t)
        partialTimesMs.removeAll { $0 < t - 5_000 }
        if audioMs > 0 {
            decodeRtf = max(0, decodeMs / audioMs)
        }
        lock.unlock()
    }

    static func markSpeechState(active: Bool, ns: UInt64) {
        let t = nowMs(ns)
        lock.lock()
        if active && !speechActive {
            speechActive = true
            lastSpeechOnsetMs = t
            speechUtteranceCount += 1

            // Start a fresh, paired latency sample. Do not let values from a
            // previous utterance coexist with a new run.
            speechToFirstPartialMs = -1
            speechToDisplayMs = -1
            firstSpeechPartialEventMs = -1
            awaitingSpeechPartial = true
            awaitingSpeechDisplay = false
            previousSpeechPartialMs = -1
        } else if !active && speechActive {
            speechActive = false
            previousSpeechPartialMs = -1
        }
        lock.unlock()
    }

    static func markEndpoint(ns: UInt64) {
        lock.lock()
        endpointCount += 1
        lastEndpointMs = nowMs(ns)
        lock.unlock()
    }

    static func markQueueDrop() {
        lock.lock()
        queueDropCount += 1
        lock.unlock()
    }

    static func markLc3SequenceGap() {
        lock.lock()
        lc3SequenceGapCount += 1
        lock.unlock()
    }

    static func markLc3DecodeFailure() {
        lock.lock()
        lc3DecodeFailureCount += 1
        lock.unlock()
    }

    static func markBackgroundGlassesKeepalive() {
        lock.lock()
        backgroundGlassesKeepaliveCount += 1
        lock.unlock()
    }

    static func markBackgroundAudioKeepalive(active: Bool) {
        lock.lock()
        if active && !backgroundAudioKeepaliveActive {
            backgroundAudioKeepaliveStarts += 1
        }
        backgroundAudioKeepaliveActive = active
        lock.unlock()
    }

    static func markTranscript(ns: UInt64) {
        lock.lock()
        lastTranscriptMs = nowMs(ns)
        lock.unlock()
    }

    static func markBridge(ns: UInt64) {
        lock.lock()
        lastBridgeMs = nowMs(ns)
        lock.unlock()
    }

    static func markDisplay(ns: UInt64) {
        let t = nowMs(ns)
        lock.lock()
        lastDisplayMs = t
        if lastTranscriptMs >= 0, t >= lastTranscriptMs, t - lastTranscriptMs < 10_000 {
            sttToDisplayMs = t - lastTranscriptMs
        }
        if awaitingSpeechDisplay,
           lastSpeechOnsetMs >= 0,
           firstSpeechPartialEventMs >= 0,
           lastTranscriptMs >= firstSpeechPartialEventMs,
           t >= firstSpeechPartialEventMs,
           t - firstSpeechPartialEventMs < 2_000
        {
            speechToDisplayMs = t - lastSpeechOnsetMs
            awaitingSpeechDisplay = false
        }
        lock.unlock()
    }

    static func snapshot() -> [String: Any] {
        let now = nowMs()
        lock.lock()
        defer { lock.unlock() }

        partialTimesMs.removeAll { $0 < now - 5_000 }
        let recentOneSecond = partialTimesMs.filter { $0 >= now - 1_000 }.count

        return [
            "nowMs": now,
            "modelState": modelState,
            "modelPath": modelPath,
            "lastError": lastError,
            "lc3AgeMs": age(lastLc3Ms, now: now),
            "pcmAgeMs": age(lastPcmMs, now: now),
            "ingestAgeMs": age(lastIngestMs, now: now),
            "decodeAgeMs": age(lastDecodeMs, now: now),
            "transcriptAgeMs": age(lastTranscriptMs, now: now),
            "bridgeAgeMs": age(lastBridgeMs, now: now),
            "displayAgeMs": age(lastDisplayMs, now: now),
            "firstPartialMs": firstPartialLatencyMs,
            "partialIntervalMs": partialIntervalMs,
            "changedPartialsPerSec": Double(recentOneSecond),
            "decodeRtf": decodeRtf,
            "decodePasses": decodePasses,
            "endpointCount": endpointCount,
            "queueDropCount": queueDropCount,
            "lc3SequenceGapCount": lc3SequenceGapCount,
            "lc3DecodeFailureCount": lc3DecodeFailureCount,
            "backgroundGlassesKeepaliveCount": backgroundGlassesKeepaliveCount,
            "backgroundAudioKeepaliveActive": backgroundAudioKeepaliveActive,
            "backgroundAudioKeepaliveStarts": backgroundAudioKeepaliveStarts,
            "longestPartialGapMs": longestPartialGapMs,
            "lastEndpointAgeMs": age(lastEndpointMs, now: now),
            "audioBacklogMs": audioBacklogMs,
            "sttToDisplayMs": sttToDisplayMs,
            "speechActive": speechActive,
            "speechUtteranceCount": speechUtteranceCount,
            "speechToFirstPartialMs": speechToFirstPartialMs,
            "speechToDisplayMs": speechToDisplayMs,
            "longestSpeechPartialGapMs": longestSpeechPartialGapMs,
        ]
    }
}

/**
 * SherpaOnnxTranscriber handles real-time audio transcription using Sherpa-ONNX.
 *
 * It works fully offline and processes PCM audio in real-time to provide partial and final ASR results.
 * This class runs on a background thread, processes short PCM chunks, and emits transcribed text using a delegate.
 */
final class SherpaOnnxTranscriber: @unchecked Sendable {
    private static let TAG = "SherpaOnnxTranscriber"

    private static let SAMPLE_RATE = 16000 // Sherpa-ONNX model's required sample rate
    private static let QUEUE_CAPACITY = 100 // Max number of audio buffers to keep in queue
    // Use several CPU threads for large streaming models. The previous single-thread
    // configuration benchmarked above real time on-device (RTF > 1), which caused
    // backlog and eventually dropped spoken words.
    private static let INFERENCE_THREADS = 3
    // Never wait just to create a batch. If several PCM chunks are already queued,
    // merge up to this much audio before crossing Swift -> sherpa/ORT so we catch up
    // with far less per-chunk decoder overhead.
    private static let MAX_CATCHUP_BATCH_MS: Double = 80.0

    private let pcmQueue = DispatchQueue(label: "com.augmentos.sherpaonnx.pcmQueue", qos: .userInteractive)
    private let pcmAvailable = DispatchSemaphore(value: 0)
    private var pcmBuffers = [Data]()
    private var isRunning = false
    private let lifecycleLock = NSLock()
    private var initializationInProgress = false
    private var nativeRecognizerCreationAttempted = false
    private var lastQueuedAudioMs: Double = 0
    private var processingQueue: DispatchQueue?
    private var processingTask: DispatchWorkItem?

    /// The underlying Sherpa-ONNX objects
    private var recognizer: SherpaOnnxRecognizer?

    private var lastPartialResult = ""

    /// Session start time for relative timestamps
    private var transcriptionSessionStart: Date

    /// Dynamic model path support
    private static var customModelPath: String? {
        guard let storedPath = STTTools.modelPathForRecognizer() else {
            return nil
        }

        // Always resolve current Documents directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Extract relative subpath after "Documents/"
        // NOTE: Doing this because the application id changes between the development builds and files can't be found.
        if let range = storedPath.range(of: "/Documents/") {
            let relativePath = String(storedPath[range.upperBound...]) // e.g. "stt_models/..."
            let fixedPath = documentsURL.appendingPathComponent(relativePath).path

            Bridge.log("Reconstructed STTModelPath: \(fixedPath)")
            return fixedPath
        }

        // If nothing matched, just return as-is
        Bridge.log("STTModelPath (raw): \(storedPath)")
        return storedPath
    }

    private static func firstExistingFile(in directory: String, candidates: [String]) -> String? {
        let fileManager = FileManager.default
        for candidate in candidates {
            let path = (directory as NSString).appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    var canInitializeSelectedModelInProcess: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return !initializationInProgress && !nativeRecognizerCreationAttempted && recognizer == nil && !isRunning
    }

    var hasActiveRecognizer: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return recognizer != nil && isRunning
    }

    private func beginInitialization() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if isRunning { return false }
        if initializationInProgress { return false }
        initializationInProgress = true
        return true
    }

    private func endInitialization() {
        lifecycleLock.lock()
        initializationInProgress = false
        lifecycleLock.unlock()
    }

    private func noteRecognizerCreationAttempt() {
        lifecycleLock.lock()
        nativeRecognizerCreationAttempted = true
        lifecycleLock.unlock()
    }

    /**
     * The recognizer loads models from filesystem paths and does not require
     * UIKit state. Keep construction independent of the app's root view so
     * early DeviceManager startup can never leave local STT permanently nil.
     */
    init() {
        transcriptionSessionStart = Date()
    }

    deinit {
        shutdown()
    }

    /**
     * Initialize the Sherpa-ONNX recognizer.
     * Loads models and configuration, sets up processing thread.
     */
    @discardableResult
    func initialize() -> Bool {
        if hasActiveRecognizer { return true }
        guard beginInitialization() else {
            G2LabDiagnostics.markError("STT initialization is already in progress")
            return false
        }
        defer { endInitialization() }

        if let selectedPath = Self.customModelPath {
            G2LabDiagnostics.markModel(state: "initializing", path: selectedPath)
        } else {
            G2LabDiagnostics.markModel(state: "no-model", path: "")
        }

        do {
            var tokensPath: String
            var modelType = "unknown"
            let fileManager = FileManager.default

            // Check if we have a custom model path set
            if let customPath = SherpaOnnxTranscriber.customModelPath {
                // Detect model type based on available files
                let ctcModelPath = Self.firstExistingFile(
                    in: customPath,
                    candidates: ["model.int8.onnx", "model.onnx"]
                )
                let transducerEncoderPath = Self.firstExistingFile(
                    in: customPath,
                    candidates: ["encoder.int8.onnx", "encoder.onnx"]
                )

                tokensPath = (customPath as NSString).appendingPathComponent("tokens.txt")

                // Verify tokens file exists
                guard fileManager.fileExists(atPath: tokensPath) else {
                    throw NSError(domain: "SherpaOnnxTranscriber", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "tokens.txt not found at path: \(customPath)",
                    ])
                }

                if let ctcModelPath {
                    // CTC model detected
                    modelType = "ctc"
                    Bridge.log("Detected CTC model at \(customPath)")

                    // Create CTC model config using Zipformer2Ctc
                    var nemoCtc = sherpaOnnxOnlineNemoCtcModelConfig(
                        model: ctcModelPath
                    )

                    // Create model config with CTC
                    var modelConfig = sherpaOnnxOnlineModelConfig(
                        tokens: tokensPath,
                        numThreads: Self.INFERENCE_THREADS,
                        nemoCtc: nemoCtc
                    )

                    // Configure recognizer
                    var featureConfig = sherpaOnnxFeatureConfig()

                    var config = sherpaOnnxOnlineRecognizerConfig(
                        featConfig: featureConfig,
                        modelConfig: modelConfig,
                        enableEndpoint: true,
                        // Continuous-caption tuning: keep partials streaming immediately,
                        // but do not reset decoder state on every short conversational pause.
                        rule1MinTrailingSilence: 2.4,
                        rule2MinTrailingSilence: 1.2,
                        rule3MinUtteranceLength: 20.0
                    )

                    // The first native recognizer construction owns ORT for this process.
                    // Never tear it down and construct a different model in-process.
                    noteRecognizerCreationAttempt()
                    recognizer = try SherpaOnnxRecognizer(config: &config)

                } else if let transducerEncoderPath {
                    // Transducer model detected
                    modelType = "transducer"
                    Bridge.log("Detected transducer model at \(customPath)")

                    let decoderPath = Self.firstExistingFile(
                        in: customPath,
                        candidates: ["decoder.int8.onnx", "decoder.onnx"]
                    )
                    let joinerPath = Self.firstExistingFile(
                        in: customPath,
                        candidates: ["joiner.int8.onnx", "joiner.onnx"]
                    )

                    // Verify all transducer files exist
                    guard let decoderPath,
                          let joinerPath
                    else {
                        throw NSError(domain: "SherpaOnnxTranscriber", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Transducer model files incomplete at path: \(customPath)",
                        ])
                    }

                    // Create Sherpa-ONNX transducer model config
                    var transducer = sherpaOnnxOnlineTransducerModelConfig(
                        encoder: transducerEncoderPath,
                        decoder: decoderPath,
                        joiner: joinerPath
                    )

                    // Create model config
                    var modelConfig = sherpaOnnxOnlineModelConfig(
                        tokens: tokensPath,
                        transducer: transducer,
                        numThreads: Self.INFERENCE_THREADS
                    )

                    // Configure recognizer
                    var featureConfig = sherpaOnnxFeatureConfig()

                    var config = sherpaOnnxOnlineRecognizerConfig(
                        featConfig: featureConfig,
                        modelConfig: modelConfig,
                        enableEndpoint: true,
                        // Continuous-caption tuning: keep partials streaming immediately,
                        // but do not reset decoder state on every short conversational pause.
                        rule1MinTrailingSilence: 2.4,
                        rule2MinTrailingSilence: 1.2,
                        rule3MinUtteranceLength: 20.0
                    )

                    // The first native recognizer construction owns ORT for this process.
                    // Never tear it down and construct a different model in-process.
                    noteRecognizerCreationAttempt()
                    recognizer = try SherpaOnnxRecognizer(config: &config)

                } else {
                    throw NSError(domain: "SherpaOnnxTranscriber", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "No valid model files found at path: \(customPath)",
                    ])
                }
            } else {
                Bridge.log("No Sherpa ONNX model available. Transcription will be disabled.")
                Bridge.log("Please download a model using the model downloader in settings.")
                recognizer = nil
                isRunning = false
                G2LabDiagnostics.markModel(state: "no-model", path: "")
                return true
            }

            if recognizer == nil {
                throw NSError(domain: "SherpaOnnxTranscriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create recognizer"])
            }

            let selectedModelPath = STTTools.modelPathForRecognizer()?.lowercased() ?? ""
            let isNemotron = selectedModelPath.contains("nemotron")
            let streamLanguage = STTTools.languageForRecognizer()

            // Multilingual Nemotron derives its numerical prompt id internally from
            // the language string plus encoder metadata. Forcing prompt_index here
            // can select the wrong prompt and produce endless empty hypotheses.
            // Generic Kroko/Zipformer transducers do not need this stream option.
            if isNemotron, let languageCode = streamLanguage, !languageCode.isEmpty {
                try recognizer?.setOption(key: "language", value: languageCode)
                Bridge.log("Sherpa Nemotron language option: \(languageCode)")
            }

            // Construction alone does not execute the first encoder pass.
            // Run a bounded readiness smoke test before declaring the model live.
            try recognizer?.smokeTest(sampleRate: Self.SAMPLE_RATE)
            try recognizer?.recreateStream()
            // recreateStream() replaces the native stream, so reapply Nemotron language.
            if isNemotron, let languageCode = streamLanguage, !languageCode.isEmpty {
                try recognizer?.setOption(key: "language", value: languageCode)
            }

            isRunning = true
            startProcessingTask()

            G2LabDiagnostics.markModel(state: "ready", path: STTTools.modelPathForRecognizer() ?? "")
            STTTools.markCurrentModelReady()
            Bridge.log("Sherpa-ONNX ASR initialized successfully with \(modelType) model")
            return true

        } catch {
            let message = error.localizedDescription
            Bridge.log("Failed to initialize Sherpa-ONNX: \(message)")
            G2LabDiagnostics.markModel(state: "failed", path: STTTools.modelPathForRecognizer() ?? "")
            G2LabDiagnostics.markError(message)
            recognizer = nil
            isRunning = false
            return false
        }
    }

    /**
     * Handle transcription results - send only to delegate
     */
    private func handleTranscriptionResult(text: String, isFinal: Bool) {
        let g2TraceResultNs = DispatchTime.now().uptimeNanoseconds
        G2LabDiagnostics.markTranscript(ns: g2TraceResultNs)
        Bridge.log("G2LAB_TRACE T3_SHERPA_RESULT ns=\(g2TraceResultNs) final=\(isFinal) chars=\(text.count) text=\(text.debugDescription)")
        // Forward to delegate if set. Measure main-queue handoff separately.
        DispatchQueue.main.async { [weak self] in
            let g2TraceMainNs = DispatchTime.now().uptimeNanoseconds
            Bridge.log("G2LAB_TRACE T4_MAIN_STT_CALLBACK ns=\(g2TraceMainNs) queueMs=\(String(format: "%.3f", Double(g2TraceMainNs - g2TraceResultNs) / 1_000_000.0)) final=\(isFinal)")
            if isFinal {
                STTTools.didReceiveFinalTranscription(text)
            } else {
                STTTools.didReceivePartialTranscription(text)
            }
        }
    }

    /**
     * Feed PCM audio data (16-bit little endian) into the transcriber.
     * This method should be called continuously with short chunks (e.g., 100-300ms).
     *
     * Audio is queued directly; microphone VAD gating is not applied in the SDK.
     */
    func acceptAudio(pcm16le: Data) {
        guard isRunning else {
            G2LabDiagnostics.markError("PCM reached STT, but no recognizer is running")
            return
        }

        queueAudioData(pcm16le)
    }

    private func queueAudioData(_ pcm16le: Data) {
        pcmQueue.async { [weak self] in
            guard let self = self else { return }

            let queueSizeBefore = self.pcmBuffers.count
            self.pcmBuffers.append(pcm16le)
            if queueSizeBefore == 0 {
                self.pcmAvailable.signal()
            }
            let g2TraceQueueNs = DispatchTime.now().uptimeNanoseconds
            let g2TraceSamples = pcm16le.count / MemoryLayout<Int16>.size
            let g2TraceAudioMs = Double(g2TraceSamples) * 1000.0 / Double(Self.SAMPLE_RATE)
            self.lastQueuedAudioMs = g2TraceAudioMs
            G2LabDiagnostics.markQueue(depth: self.pcmBuffers.count, audioMs: g2TraceAudioMs)
            Bridge.log("G2LAB_TRACE STT_QUEUE ns=\(g2TraceQueueNs) depthBefore=\(queueSizeBefore) depthAfter=\(self.pcmBuffers.count) bytes=\(pcm16le.count) audioMs=\(String(format: "%.2f", g2TraceAudioMs))")

            // Keep queue size manageable
            if self.pcmBuffers.count > Self.QUEUE_CAPACITY {
                let removedBuffer = self.pcmBuffers.removeFirst()
                G2LabDiagnostics.markQueueDrop()
                Bridge.log("⚠️ Audio queue overflow - dropped buffer of \(removedBuffer.count) bytes")
            }
        }
    }

    /**
     * Start a background task to continuously consume audio and decode using Sherpa.
     */
    private func startProcessingTask() {
        Bridge.log("🚀 Starting Sherpa-ONNX processing task...")

        processingQueue = DispatchQueue(label: "com.augmentos.sherpaonnx.processor", qos: .userInteractive)

        let workItem = DispatchWorkItem { [weak self] in
            self?.runLoop()
        }

        processingTask = workItem
        processingQueue?.async(execute: workItem)
    }

    /**
     * Main processing loop that handles transcription in real-time.
     * Pulls audio from queue, feeds into Sherpa, emits partial/final results.
     */
    private func runLoop() {
        Bridge.log("🔄 Sherpa-ONNX processing loop started")

        while isRunning {
            // Sleep until PCM actually arrives instead of polling every 10 ms.
            // This removes ~0-10 ms of avoidable scheduling jitter on every wake.
            if pcmAvailable.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                continue
            }
            if !isRunning { break }

            // Pull one chunk immediately. If a backlog already exists, merge enough
            // queued chunks to amortize native/ORT call overhead without adding any
            // intentional waiting to the low-latency path.
            var audioData: Data?
            var batchAudioMs: Double = 0
            var batchChunks = 0
            var remainingDepth = 0

            pcmQueue.sync {
                guard !self.pcmBuffers.isEmpty else { return }

                var merged = Data()
                while !self.pcmBuffers.isEmpty {
                    let next = self.pcmBuffers.removeFirst()
                    let samples = next.count / MemoryLayout<Int16>.size
                    let nextMs = Double(samples) * 1000.0 / Double(Self.SAMPLE_RATE)

                    merged.append(next)
                    batchAudioMs += nextMs
                    batchChunks += 1

                    if self.pcmBuffers.isEmpty || batchAudioMs >= Self.MAX_CATCHUP_BATCH_MS {
                        break
                    }
                }
                audioData = merged
                remainingDepth = self.pcmBuffers.count
            }

            // If batching left queued PCM behind, schedule the next drain
            // immediately without waiting for another producer signal.
            if remainingDepth > 0 {
                pcmAvailable.signal()
            }

            if let data = audioData {
                G2LabDiagnostics.markQueue(
                    depth: remainingDepth,
                    audioMs: max(self.lastQueuedAudioMs, 0)
                )
                let g2TraceDecodeStartNs = DispatchTime.now().uptimeNanoseconds
                Bridge.log("G2LAB_TRACE STT_DECODE_START ns=\(g2TraceDecodeStartNs) bytes=\(data.count) chunks=\(batchChunks) audioMs=\(String(format: "%.2f", batchAudioMs))")
                // Synchronize access to recognizer to prevent race conditions
                objc_sync_enter(self)
                defer { objc_sync_exit(self) }

                guard let recognizer = recognizer else {
                    Bridge.log("⚠️ Recognizer not available, skipping audio chunk")
                    continue
                }

                do {
                    // Convert PCM to float [-1.0, 1.0]
                    let floatBuf = toFloatArray(from: data)

                    // Pass audio data to the Sherpa-ONNX stream
                    try recognizer.acceptWaveform(samples: floatBuf, sampleRate: Self.SAMPLE_RATE)

                    // Decode continuously while model is ready
                    var decodeCount = 0
                    while try recognizer.isReady() {
                        try recognizer.decode()
                        decodeCount += 1
                    }

                    if decodeCount > 0 {
                        let g2TraceDecodeDoneNs = DispatchTime.now().uptimeNanoseconds
                        let g2TraceDecodeMs = Double(g2TraceDecodeDoneNs - g2TraceDecodeStartNs) / 1_000_000.0
                        G2LabDiagnostics.markDecodeBatch(
                            ns: g2TraceDecodeDoneNs,
                            passes: decodeCount,
                            decodeMs: g2TraceDecodeMs,
                            audioMs: batchAudioMs
                        )
                        Bridge.log("G2LAB_TRACE STT_DECODE_DONE ns=\(g2TraceDecodeDoneNs) passes=\(decodeCount) decodeMs=\(String(format: "%.3f", g2TraceDecodeMs))")
                    }

                    // If utterance endpoint detected
                    if recognizer.isEndpoint() {
                        let endpointNs = DispatchTime.now().uptimeNanoseconds
                        G2LabDiagnostics.markEndpoint(ns: endpointNs)
                        let result = recognizer.getResult()
                        let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        Bridge.log("G2LAB_TRACE ENDPOINT ns=\(endpointNs) finalChars=\(finalText.count)")

                        if !finalText.isEmpty {
                            handleTranscriptionResult(text: finalText, isFinal: true)
                        }

                        try recognizer.reset() // Start new utterance
                        lastPartialResult = ""
                    } else {
                        // Emit partial results if changed
                        let result = recognizer.getResult()
                        let partial = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                        if partial != lastPartialResult, !partial.isEmpty {
                            let g2TracePartialNs = DispatchTime.now().uptimeNanoseconds
                            let g2TraceDecodeMs = Double(g2TracePartialNs - g2TraceDecodeStartNs) / 1_000_000.0
                            G2LabDiagnostics.markPartial(ns: g2TracePartialNs, decodeMs: g2TraceDecodeMs, audioMs: batchAudioMs)
                            Bridge.log("G2LAB_TRACE FIRST_CHANGED_PARTIAL ns=\(g2TracePartialNs) decodeMs=\(String(format: "%.3f", Double(g2TracePartialNs - g2TraceDecodeStartNs) / 1_000_000.0)) chars=\(partial.count)")
                            handleTranscriptionResult(text: partial, isFinal: false)
                            lastPartialResult = partial
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    Bridge.log("❌ Error processing audio: \(message)")
                    G2LabDiagnostics.markModel(state: "failed", path: STTTools.modelPathForRecognizer() ?? "")
                    G2LabDiagnostics.markError(message)
                    isRunning = false
                    STTTools.recoverFromRuntimeFailure(error.localizedDescription)
                    return
                }
            }
        }

        Bridge.log("ASR processing thread stopped")
    }

    /**
     * Convert 16-bit PCM byte data (little-endian) to float array [-1.0, 1.0].
     */
    private func toFloatArray(from pcmData: Data) -> [Float] {
        let count = pcmData.count / 2
        var samples = [Float](repeating: 0, count: count)

        pcmData.withUnsafeBytes { (bufferPointer: UnsafeRawBufferPointer) in
            if let address = bufferPointer.baseAddress {
                let int16Pointer = address.bindMemory(to: Int16.self, capacity: count)

                for i in 0 ..< count {
                    // Convert from little-endian if needed
                    var sample = int16Pointer[i]
                    if CFByteOrderGetCurrent() == CFByteOrder(CFByteOrderBigEndian.rawValue) {
                        sample = Int16(littleEndian: sample)
                    }
                    samples[i] = Float(sample) / 32768.0
                }
            }
        }

        return samples
    }

    /**
     * Stop transcription processing.
     * This shuts down the processing thread and releases Sherpa-ONNX resources.
     */
    func shutdown() {
        Bridge.log("🛑 Shutting down SherpaOnnxTranscriber...")

        isRunning = false
        pcmAvailable.signal()
        processingTask?.cancel()

        // Synchronize access to recognizer during shutdown
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        // The recognizer will be automatically cleaned up by ARC when set to nil
        if recognizer != nil {
            Bridge.log("🧹 Cleaning up Sherpa-ONNX recognizer")
            recognizer = nil
        }

        // Clear any remaining audio buffers
        pcmQueue.sync {
            let remainingBuffers = self.pcmBuffers.count
            if remainingBuffers > 0 {
                Bridge.log("🗑️ Clearing \(remainingBuffers) remaining audio buffers")
            }
            self.pcmBuffers.removeAll()
        }

        Bridge.log("✅ SherpaOnnxTranscriber shutdown complete")
    }

    /**
     * Restarts the transcriber after a model change.
     * Shuts down existing resources, clears buffers, and reinitializes the recognizer.
     */
    func restart() {
        Bridge.log("♻️ Restarting SherpaOnnxTranscriber...")
        shutdown()
        if !initialize(), STTTools.fallbackToItalianBuiltIn(reason: "recognizer initialization failed") {
            _ = initialize()
        }
    }
}
