import Foundation

enum SpeechModelKind: String, Codable, CaseIterable {
    case onlineTransducer
    case onlineNemoCTC
    case onlineZipformerCTC
    case onlineParaformer
    case unsupportedONNX

    var displayName: String {
        switch self {
        case .onlineTransducer: return "Sherpa Online Transducer"
        case .onlineNemoCTC: return "Sherpa Online NeMo CTC"
        case .onlineZipformerCTC: return "Sherpa Online Zipformer2 CTC"
        case .onlineParaformer: return "Sherpa Online Paraformer"
        case .unsupportedONNX: return "Unknown ONNX layout"
        }
    }
}

struct SpeechModel: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var kind: SpeechModelKind
    var language: String
    var directory: String
    var notes: String
    var bundled: Bool

    var url: URL { URL(fileURLWithPath: directory, isDirectory: true) }
}

struct ModelPreset: Identifiable {
    enum Source {
        case direct([(name: String, url: URL)])
        case tarBz2(URL)
    }

    let id: String
    let name: String
    let language: String
    let kind: SpeechModelKind
    let source: Source
    let notes: String

    static let italian = ModelPreset(
        id: "italian-kroko-int8",
        name: "Italian Kroko INT8",
        language: "it-IT",
        kind: .onlineTransducer,
        source: .direct([
            ("encoder.int8.onnx", URL(string: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/encoder.int8.onnx")!),
            ("decoder.int8.onnx", URL(string: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/decoder.int8.onnx")!),
            ("joiner.int8.onnx", URL(string: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/joiner.int8.onnx")!),
            ("tokens.txt", URL(string: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/tokens.txt")!),
        ]),
        notes: "Known-good offline baseline"
    )

    static let nemotron80 = ModelPreset(
        id: "nemotron-3.5-80ms-int8",
        name: "Nemotron 3.5 80 ms INT8",
        language: "it",
        kind: .onlineTransducer,
        source: .tarBz2(URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-80ms-int8-2026-06-11.tar.bz2")!),
        notes: "Streaming multilingual · 80 ms"
    )

    static let nemotron160 = ModelPreset(
        id: "nemotron-3.5-160ms-int8",
        name: "Nemotron 3.5 160 ms INT8",
        language: "it",
        kind: .onlineTransducer,
        source: .tarBz2(URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-160ms-int8-2026-06-11.tar.bz2")!),
        notes: "Streaming multilingual · 160 ms"
    )

    static let all = [italian, nemotron80, nemotron160]
}

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var installed: [SpeechModel] = []
    @Published var selectedID: String?
    @Published var activity = "Ready"
    @Published var progress: Double = 0

    private let diagnostics: DiagnosticsStore
    private let fm = FileManager.default
    private let manifestName = "g2labs-model.json"

    init(diagnostics: DiagnosticsStore) {
        self.diagnostics = diagnostics
        bootstrapBundledItalian()
        refresh()
    }

    private var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("G2LABS/Models", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func refresh() {
        var found: [SpeechModel] = []
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let model = loadOrDetect(at: dir) { found.append(model) }
        }
        installed = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selectedID == nil { selectedID = installed.first?.id }
        diagnostics.log("models", "Model library refreshed: \(installed.count) installed")
    }

    func selectedModel() -> SpeechModel? {
        installed.first { $0.id == selectedID }
    }

    func install(_ preset: ModelPreset) async {
        activity = "Preparing \(preset.name)…"
        progress = 0
        let destination = root.appendingPathComponent(preset.id, isDirectory: true)
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            switch preset.source {
            case .direct(let files):
                for (index, item) in files.enumerated() {
                    activity = "Downloading \(item.name)…"
                    let (temp, _) = try await URLSession.shared.download(from: item.url)
                    try fm.moveItem(at: temp, to: destination.appendingPathComponent(item.name))
                    progress = Double(index + 1) / Double(files.count)
                }
            case .tarBz2(let url):
                activity = "Downloading archive…"
                let (temp, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NSError(domain: "G2LabsDownload", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from model server"])
                }
                activity = "Extracting archive…"
                try ArchiveExtractor.extractTarBz2(from: temp, to: destination) { [weak self] p in
                    Task { @MainActor in self?.progress = p }
                }
            }

            let model = try detectModel(at: destination, preferredID: preset.id, preferredName: preset.name, language: preset.language, preferredKind: preset.kind, bundled: false)
            try saveManifest(model)
            selectedID = model.id
            activity = "Installed · \(model.name)"
            progress = 1
            diagnostics.log("models", "Installed \(model.name) [\(model.kind.rawValue)]")
            refresh()
        } catch {
            try? fm.removeItem(at: destination)
            activity = "Install failed"
            diagnostics.error("models", "\(preset.name): \(error.localizedDescription)")
        }
    }

    func importFolder(_ externalURL: URL, language: String = "auto") async {
        let access = externalURL.startAccessingSecurityScopedResource()
        defer { if access { externalURL.stopAccessingSecurityScopedResource() } }
        let id = "custom-\(UUID().uuidString.lowercased())"
        let destination = root.appendingPathComponent(id, isDirectory: true)
        do {
            activity = "Copying custom model…"
            try fm.copyItem(at: externalURL, to: destination)
            let flattened = flattenIfSingleNestedDirectory(destination)
            let model = try detectModel(at: flattened, preferredID: id, preferredName: externalURL.lastPathComponent, language: language, preferredKind: nil, bundled: false)
            try saveManifest(model)
            selectedID = model.id
            activity = "Imported · \(model.name)"
            diagnostics.log("models", "Imported custom model: \(model.name) type=\(model.kind.rawValue)")
            refresh()
        } catch {
            try? fm.removeItem(at: destination)
            activity = "Import failed"
            diagnostics.error("models", error.localizedDescription)
        }
    }

    func delete(_ model: SpeechModel) {
        guard !model.bundled else { return }
        do {
            try fm.removeItem(at: model.url)
            if selectedID == model.id { selectedID = nil }
            refresh()
        } catch {
            diagnostics.error("models", "Delete failed: \(error.localizedDescription)")
        }
    }

    private func bootstrapBundledItalian() {
        let destination = root.appendingPathComponent(ModelPreset.italian.id, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path),
              let bundled = Bundle.main.resourceURL?.appendingPathComponent("BuiltinItalian", isDirectory: true),
              fm.fileExists(atPath: bundled.path)
        else { return }

        do {
            try fm.copyItem(at: bundled, to: destination)
            let model = try detectModel(at: destination, preferredID: ModelPreset.italian.id, preferredName: ModelPreset.italian.name, language: "it-IT", preferredKind: .onlineTransducer, bundled: true)
            try saveManifest(model)
            diagnostics.log("models", "Bundled Italian baseline installed")
        } catch {
            diagnostics.error("models", "Bundled Italian bootstrap failed: \(error.localizedDescription)")
        }
    }

    private func loadOrDetect(at directory: URL) -> SpeechModel? {
        let manifest = directory.appendingPathComponent(manifestName)
        if let data = try? Data(contentsOf: manifest), let model = try? JSONDecoder().decode(SpeechModel.self, from: data) {
            return model
        }
        return try? detectModel(at: directory, preferredID: directory.lastPathComponent, preferredName: directory.lastPathComponent, language: "auto", preferredKind: nil, bundled: false)
    }

    private func saveManifest(_ model: SpeechModel) throws {
        let data = try JSONEncoder().encode(model)
        try data.write(to: model.url.appendingPathComponent(manifestName), options: .atomic)
    }

    private func detectModel(at directory: URL, preferredID: String, preferredName: String, language: String, preferredKind: SpeechModelKind?, bundled: Bool) throws -> SpeechModel {
        let names = Set(recursiveFiles(in: directory).map { $0.lastPathComponent.lowercased() })
        guard names.contains("tokens.txt") else {
            throw NSError(domain: "G2LabsModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "tokens.txt is missing"])
        }

        let hasEncoder = names.contains("encoder.onnx") || names.contains("encoder.int8.onnx")
        let hasDecoder = names.contains("decoder.onnx") || names.contains("decoder.int8.onnx")
        let hasJoiner = names.contains("joiner.onnx") || names.contains("joiner.int8.onnx")
        let hasModel = names.contains("model.onnx") || names.contains("model.int8.onnx")

        let kind: SpeechModelKind
        if let preferredKind {
            kind = preferredKind
        } else if hasEncoder && hasDecoder && hasJoiner {
            kind = .onlineTransducer
        } else if hasEncoder && hasDecoder {
            kind = .onlineParaformer
        } else if hasModel {
            kind = preferredName.lowercased().contains("nemo") ? .onlineNemoCTC : .onlineZipformerCTC
        } else {
            kind = .unsupportedONNX
        }

        guard kind != .unsupportedONNX else {
            throw NSError(domain: "G2LabsModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "ONNX files found, but their speech architecture is unknown. Add a G2 LABS manifest to select an adapter."])
        }

        return SpeechModel(id: preferredID, name: preferredName, kind: kind, language: language, directory: directory.path, notes: "Auto-detected by G2 LABS", bundled: bundled)
    }

    private func recursiveFiles(in directory: URL) -> [URL] {
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    private func flattenIfSingleNestedDirectory(_ directory: URL) -> URL {
        let children = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
        if children.count == 1,
           let values = try? children[0].resourceValues(forKeys: [.isDirectoryKey]),
           values.isDirectory == true {
            return children[0]
        }
        return directory
    }
}
