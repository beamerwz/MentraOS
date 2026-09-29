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
    @Published var importMessage = "Select a model folder or .tar.bz2 archive"
    @Published var importProgress: Double = 0
    @Published var isImporting = false

    private let storageKey = "G2NativeLabs.models.v2"
    private let activeKey = "G2NativeLabs.activeModel.v2"

    init() {
        restore()
    }

    func importModel(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        importProgress = 0
        importMessage = "Preparing \(url.lastPathComponent)…"

        let scoped = url.startAccessingSecurityScopedResource()
        let source = url
        let displayName = Self.cleanDisplayName(url.lastPathComponent)

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
            }

            do {
                let root = try Self.modelRoot()
                let destination = root.appendingPathComponent(
                    "\(UUID().uuidString)-\(displayName)",
                    isDirectory: true
                )

                try NativeModelArchive.install(from: source, to: destination) { fraction, stage in
                    Task { @MainActor [weak self] in
                        self?.importProgress = fraction
                        self?.importMessage = stage
                    }
                }

                let relative = try FileManager.default.subpathsOfDirectory(atPath: destination.path)
                let lower = relative.map { $0.lowercased() }
                let family = Self.detect(files: lower, sourceName: displayName.lowercased())
                let onnx = lower.filter { $0.hasSuffix(".onnx") }
                let tokens = lower.contains { $0.hasSuffix("/tokens.txt") || $0 == "tokens.txt" }

                let hasEncoder = lower.contains { $0.contains("encoder") && $0.hasSuffix(".onnx") }
                let hasDecoder = lower.contains { $0.contains("decoder") && $0.hasSuffix(".onnx") }
                let hasJoiner = lower.contains { $0.contains("joiner") && $0.hasSuffix(".onnx") }

                let valid: Bool
                switch family {
                case .nemotron, .streamingTransducer:
                    valid = tokens && hasEncoder && hasDecoder && hasJoiner
                case .ctc:
                    valid = tokens && !onnx.isEmpty
                default:
                    valid = !onnx.isEmpty
                }

                let detail =
                    "Detected \(family.rawValue) • \(onnx.count) ONNX • tokens \(tokens ? "OK" : "MISSING")" +
                    ((family == .nemotron || family == .streamingTransducer)
                     ? " • E/D/J \(hasEncoder && hasDecoder && hasJoiner ? "OK" : "INCOMPLETE")"
                     : "")

                let model = ASRModel(
                    name: displayName,
                    family: family,
                    location: destination,
                    validated: valid,
                    validationMessage: detail
                )

                await MainActor.run {
                    guard let self else { return }
                    self.models.append(model)
                    self.importProgress = 1
                    self.importMessage = valid ? "IMPORT PASS • \(detail)" : "IMPORT CHECK • \(detail)"
                    self.isImporting = false
                    self.persist()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.importMessage = "IMPORT ERROR: \(error.localizedDescription)"
                    self.isImporting = false
                }
            }
        }
    }

    func markActive(_ model: ASRModel) {
        activeID = model.id
        UserDefaults.standard.set(model.id.uuidString, forKey: activeKey)
    }

    func delete(_ model: ASRModel) {
        try? FileManager.default.removeItem(at: model.location)
        models.removeAll { $0.id == model.id }
        if activeID == model.id { activeID = nil }
        persist()
    }

    nonisolated static func detect(files: [String], sourceName: String = "") -> ASRFamily {
        let joined = ([sourceName] + files).joined(separator: " ")
        if joined.contains("nemotron") || joined.contains("nemo") { return .nemotron }
        if joined.contains("whisper") { return .whisper }
        if joined.contains("moonshine") { return .moonshine }
        if joined.contains("sense") && joined.contains("voice") { return .senseVoice }
        if joined.contains("paraformer") { return .paraformer }
        if joined.contains("encoder") && joined.contains("decoder") && joined.contains("joiner") {
            return .streamingTransducer
        }
        if joined.contains("ctc") || files.filter({ $0.hasSuffix(".onnx") }).count == 1 {
            return .ctc
        }
        return .unknown
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func restore() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ASRModel].self, from: data) {
            models = decoded.filter { FileManager.default.fileExists(atPath: $0.location.path) }
        }
        if let raw = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: raw),
           models.contains(where: { $0.id == id }) {
            activeID = id
        }
    }

    nonisolated private static func modelRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("ASRModels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated private static func cleanDisplayName(_ file: String) -> String {
        let lower = file.lowercased()
        if lower.hasSuffix(".tar.bz2") { return String(file.dropLast(8)) }
        if lower.hasSuffix(".tbz2") { return String(file.dropLast(5)) }
        if lower.hasSuffix(".bz2") { return String(file.dropLast(4)) }
        return file
    }
}
