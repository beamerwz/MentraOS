import Foundation
import UniformTypeIdentifiers

enum ASRFamily: String, Codable, CaseIterable {
    case streamingTransducer = "Streaming Transducer / Zipformer"
    case nemotron = "Nemotron / NeMo Transducer"
    case ctc = "CTC"
    case paraformer = "Paraformer"
    case whisper = "Whisper"
    case moonshine = "Moonshine"
    case senseVoice = "SenseVoice"
    case unknown = "Unknown / inspect first"
}

struct ASRModel: Identifiable, Codable {
    var id = UUID()
    var name: String
    var family: ASRFamily
    var location: URL
    var validated: Bool
    var validationMessage: String
}

@MainActor
final class ModelRegistry: ObservableObject {
    @Published var models: [ASRModel] = []
    @Published var activeID: UUID?
    @Published var importMessage = "No model imported yet"

    func importFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            let dstRoot = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true).appendingPathComponent("ASRModels", isDirectory: true)
            try fm.createDirectory(at: dstRoot, withIntermediateDirectories: true)
            let dst = dstRoot.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)", isDirectory: true)
            try fm.copyItem(at: url, to: dst)
            let files = try fm.subpathsOfDirectory(atPath: dst.path).map { $0.lowercased() }
            let family = Self.detect(files)
            let onnx = files.filter { $0.hasSuffix(".onnx") }
            let tokens = files.contains { $0.hasSuffix("tokens.txt") || $0.hasSuffix("tokens.json") }
            let ok = !onnx.isEmpty
            let detail = "Detected \(family.rawValue) • \(onnx.count) ONNX file(s) • tokens \(tokens ? "present" : "not found")"
            let m = ASRModel(name: url.lastPathComponent, family: family, location: dst, validated: ok, validationMessage: detail)
            models.append(m)
            importMessage = detail
        } catch {
            importMessage = "IMPORT ERROR: \(error.localizedDescription)"
        }
    }

    static func detect(_ files: [String]) -> ASRFamily {
        let joined = files.joined(separator: " ")
        if joined.contains("nemotron") || joined.contains("nemo") { return .nemotron }
        if joined.contains("whisper") { return .whisper }
        if joined.contains("moonshine") { return .moonshine }
        if joined.contains("sense") && joined.contains("voice") { return .senseVoice }
        if joined.contains("paraformer") { return .paraformer }
        if joined.contains("encoder") && joined.contains("decoder") && joined.contains("joiner") { return .streamingTransducer }
        if joined.contains("ctc") || files.filter({ $0.hasSuffix(".onnx") }).count == 1 { return .ctc }
        return .unknown
    }
}
