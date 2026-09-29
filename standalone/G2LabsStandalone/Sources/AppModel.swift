import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum InputSource: String, CaseIterable, Identifiable {
        case phone = "iPhone Mic"
        case glasses = "G2 Glasses Mic"
        var id: String { rawValue }
    }

    let diagnostics: DiagnosticsStore
    let models: ModelLibrary
    let g2: G2Transport

    @Published var inputSource: InputSource = .glasses
    @Published var isRunning = false
    @Published var status = "Ready"
    @Published var liveText = ""
    @Published var finalLines: [String] = []

    private let speech: SpeechRuntime
    private let phone: PhoneMicSource

    init() {
        let diagnostics = DiagnosticsStore()
        self.diagnostics = diagnostics
        self.models = ModelLibrary(diagnostics: diagnostics)
        self.g2 = G2Transport(diagnostics: diagnostics)
        self.speech = SpeechRuntime(diagnostics: diagnostics)
        self.phone = PhoneMicSource(diagnostics: diagnostics)

        phone.onPCM = { [weak self] pcm in
            Task { @MainActor in self?.ingest(pcm, source: "phone") }
        }
        g2.onPCM = { [weak self] pcm in
            Task { @MainActor in self?.ingest(pcm, source: "g2") }
        }
        speech.onResult = { [weak self] text, final in
            guard let self else { return }
            self.liveText = text
            if final {
                self.finalLines.append(text)
                if self.finalLines.count > 30 { self.finalLines.removeFirst() }
            }
            if self.g2.connected {
                self.g2.sendCaption(text)
            }
        }
    }

    func connectG2() {
        g2.scan()
    }

    func start() {
        guard !isRunning else { return }
        guard let model = models.selectedModel() else {
            status = "Select a model first"
            diagnostics.error("pipeline", "No speech model selected")
            return
        }

        status = "Loading \(model.name)…"
        diagnostics.resetCounters()
        diagnostics.log("pipeline", "Starting with \(model.name), input=\(inputSource.rawValue)")
        speech.load(model) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        if self.inputSource == .phone {
                            try await self.phone.start()
                        } else if !self.g2.connected {
                            self.status = "Connect G2 first, or switch to iPhone Mic"
                            self.diagnostics.error("pipeline", "G2 input selected but direct G2 session is not ready")
                            return
                        }
                        self.isRunning = true
                        self.status = "Listening · \(model.name)"
                    } catch {
                        self.status = "Input failed"
                        self.diagnostics.error("pipeline", error.localizedDescription)
                    }
                case .failure(let error):
                    self.status = "Model failed smoke test"
                    self.diagnostics.error("pipeline", error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        if inputSource == .phone { phone.stop() }
        speech.unload()
        isRunning = false
        status = "Stopped"
        diagnostics.log("pipeline", "Stopped")
    }

    func switchInput(_ source: InputSource) {
        if isRunning { stop() }
        inputSource = source
    }

    private func ingest(_ pcm: Data, source: String) {
        guard isRunning else { return }
        if source == "g2" && inputSource != .glasses { return }
        if source == "phone" && inputSource != .phone { return }
        speech.acceptPCM16(pcm)
    }
}
