import AVFoundation
import Foundation

final class PhoneMicSource {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private weak var diagnostics: DiagnosticsStore?
    var onPCM: ((Data) -> Void)?

    init(diagnostics: DiagnosticsStore) {
        self.diagnostics = diagnostics
    }

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "G2LabsPhoneMic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create 16 kHz audio converter"])
        }
        self.converter = converter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
        await MainActor.run { self.diagnostics?.log("phone-mic", "Phone microphone started: \(Int(inputFormat.sampleRate)) Hz → 16000 Hz") }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        Task { @MainActor in diagnostics?.log("phone-mic", "Phone microphone stopped") }
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(max(32, ceil(Double(input.frameLength) * ratio) + 32))
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }

        guard conversionError == nil, status != .error, out.frameLength > 0,
              let floats = out.floatChannelData?[0]
        else {
            if let conversionError {
                Task { @MainActor in self.diagnostics?.error("phone-mic", conversionError.localizedDescription) }
            }
            return
        }

        var pcm = Data(count: Int(out.frameLength) * 2)
        var peak: Float = 0
        pcm.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(out.frameLength) {
                let value = max(-1, min(1, floats[i]))
                peak = max(peak, abs(value))
                dst[i] = Int16(value * 32767).littleEndian
            }
        }

        Task { @MainActor in
            self.diagnostics?.pcmFrames += 1
            self.diagnostics?.audioLevel = Double(peak)
        }
        onPCM?(pcm)
    }
}
