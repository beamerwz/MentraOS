import Foundation

@MainActor
final class DiagnosticsStore: ObservableObject {
    struct Event: Identifiable, Codable {
        let id: UUID
        let time: Date
        let stage: String
        let message: String
        let value: Double?

        init(stage: String, message: String, value: Double? = nil) {
            id = UUID()
            time = Date()
            self.stage = stage
            self.message = message
            self.value = value
        }
    }

    @Published private(set) var events: [Event] = []
    @Published var bleState = "idle"
    @Published var leftConnected = false
    @Published var rightConnected = false
    @Published var lc3Frames = 0
    @Published var pcmFrames = 0
    @Published var recognizerFrames = 0
    @Published var partials = 0
    @Published var finals = 0
    @Published var displayWrites = 0
    @Published var audioLevel: Double = 0
    @Published var lastPartialLatencyMs: Double?
    @Published var decodeRtf: Double?
    @Published var lastError = ""

    func log(_ stage: String, _ message: String, value: Double? = nil) {
        events.append(Event(stage: stage, message: message, value: value))
        if events.count > 1200 { events.removeFirst(events.count - 1200) }
    }

    func error(_ stage: String, _ message: String) {
        lastError = message
        log(stage, "ERROR: \(message)")
    }

    func resetCounters() {
        lc3Frames = 0
        pcmFrames = 0
        recognizerFrames = 0
        partials = 0
        finals = 0
        displayWrites = 0
        audioLevel = 0
        lastPartialLatencyMs = nil
        decodeRtf = nil
        lastError = ""
        log("diagnostics", "Counters reset")
    }

    func exportURL() -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = ExportEnvelope(
            generatedAt: Date(),
            bleState: bleState,
            leftConnected: leftConnected,
            rightConnected: rightConnected,
            lc3Frames: lc3Frames,
            pcmFrames: pcmFrames,
            recognizerFrames: recognizerFrames,
            partials: partials,
            finals: finals,
            displayWrites: displayWrites,
            audioLevel: audioLevel,
            lastPartialLatencyMs: lastPartialLatencyMs,
            decodeRtf: decodeRtf,
            lastError: lastError,
            events: events
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("G2LABS_Diagnosis_\(Int(Date().timeIntervalSince1970)).json")
        do {
            try encoder.encode(envelope).write(to: url, options: .atomic)
            return url
        } catch {
            self.error("diagnostics", "Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct ExportEnvelope: Codable {
        let generatedAt: Date
        let bleState: String
        let leftConnected: Bool
        let rightConnected: Bool
        let lc3Frames: Int
        let pcmFrames: Int
        let recognizerFrames: Int
        let partials: Int
        let finals: Int
        let displayWrites: Int
        let audioLevel: Double
        let lastPartialLatencyMs: Double?
        let decodeRtf: Double?
        let lastError: String
        let events: [Event]
    }
}
