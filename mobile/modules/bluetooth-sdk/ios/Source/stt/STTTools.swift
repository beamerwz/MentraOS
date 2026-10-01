import Foundation

class STTTools {
    private static let nemotronMarker = ".g2labs-nemotron-v2"
    private static var stagedModel: (path: String, languageCode: String)?

    // Crash guard for untrusted/custom models.
    // staged -> constructing -> loaded -> testing -> proven.
    //
    // Important: a model is NOT trusted just because ONNX sessions were created.
    // We only clear the guard after a real live decoder pass returns successfully.
    // This catches hard native crashes such as NeMo RunDecoder heap corruption.
    private static let activationStateKey = "G2LabsSTTActivationState"
    private static let candidatePathKey = "G2LabsSTTCandidatePath"
    private static let candidateLanguageKey = "G2LabsSTTCandidateLanguage"
    private static let lastGoodPathKey = "G2LabsSTTLastKnownGoodPath"
    private static let lastGoodLanguageKey = "G2LabsSTTLastKnownGoodLanguage"
    private static let lastRecoveryReasonKey = "G2LabsSTTLastRecoveryReason"

    private enum ActivationState: String {
        case staged
        case constructing
        case loaded
        case testing
    }

    static func modelPathForRecognizer() -> String? {
        return stagedModel?.path ?? UserDefaults.standard.string(forKey: "STTModelPath")
    }

    static func languageForRecognizer() -> String? {
        return stagedModel?.languageCode ?? UserDefaults.standard.string(forKey: "STTModelLanguageCode")
    }

    static func stageSttModelDetails(_ path: String, _ languageCode: String) {
        stagedModel = (path, languageCode)
    }

    static func commitStagedModel() {
        guard let stagedModel else { return }
        setSttModelDetails(stagedModel.path, stagedModel.languageCode)
        self.stagedModel = nil
    }

    static func clearStagedModel() {
        stagedModel = nil
    }

    // Local model runtimes sometimes use ISO-639-1 codes internally (Nemotron
    // uses "it"), while the miniapp transcription API subscribes with canonical
    // BCP-47 tags ("it-IT"). Normalize only the event tag; keep the raw model
    // language available to Sherpa's per-stream option.
    private static func eventLanguageTag(_ raw: String) -> String {
        if raw.contains("-") { return raw }
        switch raw.lowercased() {
        case "it": return "it-IT"
        case "en": return "en-US"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "zh": return "zh-CN"
        case "ko": return "ko-KR"
        default: return raw
        }
    }

    // MARK: - SherpaOnnxTranscriber / STT Model Management

    static func didReceivePartialTranscription(_ text: String) {
        let g2TraceBridgeNs = DispatchTime.now().uptimeNanoseconds
        G2LabDiagnostics.markBridge(ns: g2TraceBridgeNs)
        // Send partial result to server witgetConnectedBluetoothNameh proper formatting
        let transcriptionLanguage = eventLanguageTag(
            UserDefaults.standard.string(forKey: "STTModelLanguageCode") ?? "en-US"
        )
        // Bridge.log("Mentra: Sending partial transcription: \(text), \(transcriptionLanguage)")
        let transcription: [String: Any] = [
            "type": "local_transcription",
            "text": transcriptionLanguage == "en-US" ? text.lowercased() : text,
            "isFinal": false,
            "startTime": Int(Date().timeIntervalSince1970 * 1000) - 1000, // 1 second ago
            "endTime": Int(Date().timeIntervalSince1970 * 1000),
            "speakerId": 0,
            "transcribeLanguage": transcriptionLanguage,
            "provider": "sherpa-onnx",
        ]

        Bridge.sendLocalTranscription(transcription: transcription)
    }

    static func didReceiveFinalTranscription(_ text: String) {
        let g2TraceBridgeNs = DispatchTime.now().uptimeNanoseconds
        G2LabDiagnostics.markBridge(ns: g2TraceBridgeNs)
        // Send final result to server with proper formatting
        let transcriptionLanguage = eventLanguageTag(
            UserDefaults.standard.string(forKey: "STTModelLanguageCode") ?? "en-US"
        )
        Bridge.log("Mentra: Sending final transcription: \(text), \(transcriptionLanguage)")
        if !text.isEmpty {
            let transcription: [String: Any] = [
                "type": "local_transcription",
                "text": transcriptionLanguage == "en-US" ? text.lowercased() : text,
                "isFinal": true,
                "startTime": Int(Date().timeIntervalSince1970 * 1000) - 2000, // 2 seconds ago
                "endTime": Int(Date().timeIntervalSince1970 * 1000),
                "speakerId": 0,
                "transcribeLanguage": transcriptionLanguage,
                "provider": "sherpa-onnx",
            ]

            Bridge.sendLocalTranscription(transcription: transcription)
        }
    }

    static func setSttModelDetails(_ path: String, _ languageCode: String) {
        UserDefaults.standard.set(path, forKey: "STTModelPath")
        UserDefaults.standard.set(languageCode, forKey: "STTModelLanguageCode")
        UserDefaults.standard.synchronize()
    }

    private static func clearActivationGuard() {
        UserDefaults.standard.removeObject(forKey: activationStateKey)
        UserDefaults.standard.removeObject(forKey: candidatePathKey)
        UserDefaults.standard.removeObject(forKey: candidateLanguageKey)
        UserDefaults.standard.synchronize()
    }

    private static func rememberLastKnownGood(path: String, languageCode: String) {
        guard !path.isEmpty, validateSTTModel(path) else { return }
        UserDefaults.standard.set(path, forKey: lastGoodPathKey)
        UserDefaults.standard.set(languageCode, forKey: lastGoodLanguageKey)
        UserDefaults.standard.synchronize()
    }

    /// Persist a candidate while retaining a rollback target that has already
    /// survived native recognizer initialization.
    static func stageCandidateForActivation(_ path: String, _ languageCode: String) {
        let defaults = UserDefaults.standard
        let currentPath = defaults.string(forKey: "STTModelPath") ?? ""
        let currentLanguage = defaults.string(forKey: "STTModelLanguageCode") ?? "it-IT"

        if currentPath != path {
            rememberLastKnownGood(path: currentPath, languageCode: currentLanguage)
        }

        defaults.set(path, forKey: candidatePathKey)
        defaults.set(languageCode, forKey: candidateLanguageKey)
        defaults.set(ActivationState.staged.rawValue, forKey: activationStateKey)
        defaults.set(path, forKey: "STTModelPath")
        defaults.set(languageCode, forKey: "STTModelLanguageCode")
        defaults.synchronize()
    }

    /// Arm the crash guard immediately before native ORT/Sherpa construction.
    /// If the process dies while constructing, the next launch rolls back.
    static func beginCandidateConstructionIfNeeded() {
        let defaults = UserDefaults.standard
        let state = defaults.string(forKey: activationStateKey)
        guard state == ActivationState.staged.rawValue || state == ActivationState.loaded.rawValue else {
            return
        }
        defaults.set(ActivationState.constructing.rawValue, forKey: activationStateKey)
        defaults.synchronize()
    }

    /// Native construction + bounded smoke test succeeded, but the model has not
    /// yet survived a real streaming decoder pass. Keep the rollback guard armed.
    static func markCandidateLoadedAwaitingLiveDecode() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: activationStateKey) == ActivationState.constructing.rawValue else {
            return
        }
        defaults.set(ActivationState.loaded.rawValue, forKey: activationStateKey)
        defaults.synchronize()
    }

    /// Mark the narrow risky window immediately before a real live decode.
    /// A SIGTRAP / EXC_BAD_ACCESS / malloc abort during decoder execution leaves
    /// this marker behind so the next clean launch restores the previous model.
    static func armCandidateLiveDecodeIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: activationStateKey) == ActivationState.loaded.rawValue else {
            return
        }
        defaults.set(ActivationState.testing.rawValue, forKey: activationStateKey)
        defaults.synchronize()
    }

    /// A real decoder call returned successfully. The candidate has now passed
    /// the failure mode that structural validation and startup smoke tests miss.
    static func markCandidateLiveDecodeSucceeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: activationStateKey) == ActivationState.testing.rawValue else {
            return
        }
        markCurrentModelReady()
    }

    static func markCurrentModelReady() {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: "STTModelPath") ?? ""
        let language = defaults.string(forKey: "STTModelLanguageCode") ?? "it-IT"
        rememberLastKnownGood(path: path, languageCode: language)
        clearActivationGuard()
        defaults.removeObject(forKey: lastRecoveryReasonKey)
        defaults.synchronize()
    }

    private static func isKnownUnsafePersistedModel(_ path: String) -> Bool {
        let value = path.lowercased()
        return value.contains("nemo-fast-conformer") && value.contains("transducer")
    }

    private static func restoreLastKnownGood(reason: String) -> Bool {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: lastGoodPathKey) ?? ""
        let language = defaults.string(forKey: lastGoodLanguageKey) ?? "it-IT"

        if !path.isEmpty, validateSTTModel(path) {
            Bridge.log("STT crash guard: \(reason); restoring last-known-good model \(path)")
            defaults.set(path, forKey: "STTModelPath")
            defaults.set(language, forKey: "STTModelLanguageCode")
            defaults.set(reason, forKey: lastRecoveryReasonKey)
            clearActivationGuard()
            defaults.synchronize()
            return true
        }

        clearActivationGuard()
        return forceItalianBuiltIn(reason: reason)
    }

    /// Model selection is constructed only once per clean process launch.
    /// Do not rewrite a valid persisted selection here: live teardown/recreate is
    /// deliberately avoided because it can invalidate ORT's global API on iOS.
    static func recoverPersistedModelBeforeInitialization() {
        let defaults = UserDefaults.standard
        let state = defaults.string(forKey: activationStateKey)

        // A previous process died either while creating ORT/Sherpa state or
        // inside a real live decoder call. Both are hard-crash zones that Swift
        // cannot catch, so restore the last model proven by a successful decode.
        if state == ActivationState.constructing.rawValue || state == ActivationState.testing.rawValue {
            _ = restoreLastKnownGood(reason: "previous candidate crashed during native activation/decode")
            return
        }

        // staged / loaded are retryable states. "loaded" means the prior process
        // exited before any real live decode occurred; that is not evidence of a
        // bad model, so do not falsely roll it back.

        guard let modelPath = defaults.string(forKey: "STTModelPath") else { return }

        // 3.1.7 could clear the candidate guard after startup smoke testing even
        // though this model family later corrupts memory in the real decoder.
        // Recover immediately on upgrade before ORT ever sees it again.
        if isKnownUnsafePersistedModel(modelPath) {
            _ = restoreLastKnownGood(reason: "blocked NeMo FastConformer Transducer on iOS after reproduced decoder heap corruption")
            return
        }

        if !validateSTTModel(modelPath) {
            _ = restoreLastKnownGood(reason: "persisted STT model is incomplete")
        }
    }

    @discardableResult
    static func fallbackToItalianBuiltIn(reason: String) -> Bool {
        clearActivationGuard()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let italianPath = documents.appendingPathComponent("stt_models/it").path
        if validateSTTModel(italianPath) {
            let currentPath = UserDefaults.standard.string(forKey: "STTModelPath") ?? ""
            if currentPath.hasSuffix("/stt_models/it") {
                Bridge.log("STT recovery: \(reason); Italian Built-in also failed, disabling local STT")
                UserDefaults.standard.removeObject(forKey: "STTModelPath")
                UserDefaults.standard.removeObject(forKey: "STTModelLanguageCode")
                UserDefaults.standard.synchronize()
                return false
            }
            Bridge.log("STT recovery: \(reason); activating Italian Built-in")
            setSttModelDetails(italianPath, "it-IT")
            return true
        }

        Bridge.log("STT recovery: \(reason); Italian Built-in is unavailable, disabling local STT")
        UserDefaults.standard.removeObject(forKey: "STTModelPath")
        UserDefaults.standard.removeObject(forKey: "STTModelLanguageCode")
        UserDefaults.standard.synchronize()
        return false
    }

    @discardableResult
    static func forceItalianBuiltIn(reason: String) -> Bool {
        clearStagedModel()
        clearActivationGuard()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let italianPath = documents.appendingPathComponent("stt_models/it").path
        guard validateSTTModel(italianPath) else {
            UserDefaults.standard.removeObject(forKey: "STTModelPath")
            UserDefaults.standard.removeObject(forKey: "STTModelLanguageCode")
            UserDefaults.standard.synchronize()
            return false
        }
        Bridge.log("STT recovery: \(reason); activating Italian Built-in")
        setSttModelDetails(italianPath, "it-IT")
        return true
    }

    static func recoverFromRuntimeFailure(_ detail: String) {
        let changed = fallbackToItalianBuiltIn(reason: "native decode failed: \(detail)")
        if changed {
            Bridge.log("STT recovery staged for next clean launch; live ORT restart intentionally suppressed")
        }
    }

    static func getSttModelPath() -> String {
        return UserDefaults.standard.string(forKey: "STTModelPath") ?? ""
    }

    static func checkSTTModelAvailable() -> Bool {
        guard let modelPath = UserDefaults.standard.string(forKey: "STTModelPath") else {
            return false
        }

        let fileManager = FileManager.default

        // Check for tokens.txt (required for all models)
        let tokensPath = (modelPath as NSString).appendingPathComponent("tokens.txt")
        if !fileManager.fileExists(atPath: tokensPath) {
            return false
        }

        // Check for CTC model
        if firstExistingFile(in: modelPath, candidates: ["model.int8.onnx", "model.onnx"]) != nil {
            return true
        }

        // Check for transducer model
        let transducerFiles = [
            ["encoder.onnx", "encoder.int8.onnx"],
            ["decoder.onnx", "decoder.int8.onnx"],
            ["joiner.onnx", "joiner.int8.onnx"],
        ]
        for candidates in transducerFiles {
            if firstExistingFile(in: modelPath, candidates: candidates) == nil {
                return false
            }
        }

        return true
    }

    static func validateSTTModel(_ path: String) -> Bool {
        // do {
        let fileManager = FileManager.default

        // Check for tokens.txt (required for all models)
        let tokensPath = (path as NSString).appendingPathComponent("tokens.txt")
        if !fileManager.fileExists(atPath: tokensPath) {
            return false
        }

        // Check for CTC model
        if firstExistingFile(in: path, candidates: ["model.int8.onnx", "model.onnx"]) != nil {
            return true
        }

        // Check for transducer model
        let transducerFiles = [
            ["encoder.onnx", "encoder.int8.onnx"],
            ["decoder.onnx", "decoder.int8.onnx"],
            ["joiner.onnx", "joiner.int8.onnx"],
        ]
        var allTransducerFilesPresent = true

        for candidates in transducerFiles {
            if firstExistingFile(in: path, candidates: candidates) == nil {
                allTransducerFilesPresent = false
                break
            }
        }

        return allTransducerFilesPresent
        // } catch {
        // Bridge.log("STT_ERROR: \(error.localizedDescription)")
        // return false
        // }
    }

    static func extractTarBz2(sourcePath: String, destinationPath: String) -> Bool {
        do {
            let fileManager = FileManager.default

            // Create destination directory if it doesn't exist
            try fileManager.createDirectory(
                atPath: destinationPath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Use the Swift TarBz2Extractor with SWCompression
            var extractionError: NSError?
            let success = TarBz2Extractor.extractTarBz2From(
                sourcePath,
                to: destinationPath,
                error: &extractionError
            )

            if !success || extractionError != nil {
                print(
                    "EXTRACTION_ERROR: \(extractionError?.localizedDescription ?? "Failed to extract tar.bz2")"
                )
                return false
            }

        } catch {
            Bridge.log("EXTRACTION_ERROR: \(error.localizedDescription)")
            return false
        }
        return true
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
}
