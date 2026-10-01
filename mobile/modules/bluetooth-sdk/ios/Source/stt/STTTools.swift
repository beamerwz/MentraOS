import Foundation

class STTTools {
    private static let nemotronMarker = ".g2labs-nemotron-v2"
    private static var stagedModel: (path: String, languageCode: String)?

    // Two-phase activation guard for untrusted/custom models.
    // staged -> next clean launch marks testing -> recognizer smoke test must clear it.
    // If the process dies while state == testing, the next launch automatically
    // restores the last model that completed a native smoke test.
    private static let activationStateKey = "G2LabsSTTActivationState"
    private static let candidatePathKey = "G2LabsSTTCandidatePath"
    private static let candidateLanguageKey = "G2LabsSTTCandidateLanguage"
    private static let lastGoodPathKey = "G2LabsSTTLastKnownGoodPath"
    private static let lastGoodLanguageKey = "G2LabsSTTLastKnownGoodLanguage"
    private static let lastRecoveryReasonKey = "G2LabsSTTLastRecoveryReason"

    private enum ActivationState: String {
        case staged
        case testing
    }

    static func modelPathForRecognizer() -> String? {
        return stagedModel?.path ?? UserDefaults.standard.string(forKey: "STTModelPath")
    }

    static func languageForRecognizer() -> String? {
        return stagedModel?.languageCode ?? UserDefaults.standard.string(forKey: "STTModelLanguageCode")
    }

    static func runtimeForRecognizer() -> String {
        guard let path = modelPathForRecognizer() else { return "sherpa-onnx" }
        return runtimeForModelPath(path)
    }

    static func runtimeForModelPath(_ path: String) -> String {
        let metadata = (path as NSString).appendingPathComponent(".g2labs-model.json")
        if let data = FileManager.default.contents(atPath: metadata),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let runtime = object["runtime"] as? String,
           !runtime.isEmpty
        {
            return runtime
        }
        if whisperCppModelFile(in: path) != nil { return "whisper.cpp" }
        return "sherpa-onnx"
    }

    static func whisperCppModelFile(in directory: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > 128 { break }
            if url.pathExtension.lowercased() == "bin",
               url.lastPathComponent.lowercased().contains("ggml") ||
               runtimeMetadataSaysWhisper(directory)
            {
                return url.path
            }
        }
        return nil
    }

    private static func runtimeMetadataSaysWhisper(_ directory: String) -> Bool {
        let metadata = (directory as NSString).appendingPathComponent(".g2labs-model.json")
        guard let data = FileManager.default.contents(atPath: metadata),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtime = object["runtime"] as? String
        else { return false }
        return runtime == "whisper.cpp"
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
        G2LabDiagnostics.trace("G2LAB_TRACE T5_NATIVE_BRIDGE ns=\(g2TraceBridgeNs) final=false chars=\(text.count)")
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
        G2LabDiagnostics.trace("G2LAB_TRACE T5_NATIVE_BRIDGE ns=\(g2TraceBridgeNs) final=true chars=\(text.count)")
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

    /// Called immediately before attempting candidate construction in the same
    /// process. Clean-launch candidates are transitioned in recovery below.
    static func beginStagedModelTestIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: activationStateKey) == ActivationState.staged.rawValue else {
            return
        }
        defaults.set(ActivationState.testing.rawValue, forKey: activationStateKey)
        defaults.synchronize()
    }

    /// A real native smoke test + stream recreation completed. The current
    /// selection is now safe enough to become the new rollback point.
    static func markCurrentModelReady() {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: "STTModelPath") ?? ""
        let language = defaults.string(forKey: "STTModelLanguageCode") ?? "it-IT"
        rememberLastKnownGood(path: path, languageCode: language)
        clearActivationGuard()
        defaults.removeObject(forKey: lastRecoveryReasonKey)
        defaults.synchronize()
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

        // A previous launch reached the risky native construction phase but
        // never reported readiness. Treat that as a failed/crashed candidate.
        if state == ActivationState.testing.rawValue {
            _ = restoreLastKnownGood(reason: "previous candidate did not finish native activation")
            return
        }

        // First clean launch after staging: arm the crash detector BEFORE ONNX
        // Runtime is touched. A hard native crash leaves this marker behind.
        if state == ActivationState.staged.rawValue {
            defaults.set(ActivationState.testing.rawValue, forKey: activationStateKey)
            defaults.synchronize()
        }

        guard let modelPath = defaults.string(forKey: "STTModelPath") else { return }
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
        if runtimeForModelPath(modelPath) == "whisper.cpp" {
            return whisperCppModelFile(in: modelPath) != nil
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
        if runtimeForModelPath(path) == "whisper.cpp" {
            return whisperCppModelFile(in: path) != nil
        }

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
