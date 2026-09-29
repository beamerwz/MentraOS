import SwiftUI
import UniformTypeIdentifiers

struct ConnectionView: View {
    @EnvironmentObject var g2: G2Transport
    var body: some View {
        NavigationStack {
            List {
                Section("DIRECT G2") {
                    LabeledContent("Bluetooth", value: g2.bluetoothState)
                    LabeledContent("Connected", value: g2.connectedName ?? "No")
                    Button("Scan") { g2.scan() }
                    ForEach(g2.discovered, id: \.identifier) { p in
                        Button(p.name ?? p.identifier.uuidString) { g2.connect(p) }
                    }
                }
                Section("RAW AUDIO PROOF") {
                    LabeledContent("Audio packets", value: "\(g2.audioPackets)")
                    LabeledContent("Audio bytes", value: "\(g2.audioBytes)")
                    LabeledContent("Last audio", value: g2.lastAudioAt?.formatted(date: .omitted, time: .standard) ?? "Never")
                }
            }.navigationTitle("G2 LABS Native")
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject var registry: ModelRegistry
    @State private var importing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Import model folder") { importing = true }
                    Text(registry.importMessage).font(.caption)
                } header: { Text("ONE MODEL REGISTRY") }
                Section("Installed") {
                    if registry.models.isEmpty { Text("No models").foregroundStyle(.secondary) }
                    ForEach(registry.models) { m in
                        VStack(alignment: .leading) {
                            Text(m.name).font(.headline)
                            Text(m.family.rawValue)
                            Text(m.validationMessage).font(.caption).foregroundStyle(m.validated ? .green : .orange)
                        }
                    }
                }
            }.navigationTitle("Models")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { registry.importFolder(url) }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var g2: G2Transport
    var body: some View {
        NavigationStack {
            List {
                Section("PIPELINE") {
                    DiagnosticRow("BLE link", ok: g2.connectedName != nil, detail: g2.connectedName ?? "Not connected")
                    DiagnosticRow("G2 audio packets", ok: g2.audioPackets > 0, detail: "\(g2.audioPackets) packets / \(g2.audioBytes) bytes")
                    DiagnosticRow("PCM decode", ok: false, detail: "Next gate: LC3 decoder")
                    DiagnosticRow("ASR recognizer", ok: false, detail: "Not started")
                    DiagnosticRow("Caption display", ok: false, detail: "Not started")
                }
                Section("EVENT LOG") {
                    ForEach(Array(g2.events.enumerated()), id: \.offset) { _, e in
                        Text(e).font(.system(.caption, design: .monospaced))
                    }
                }
                if let e = g2.lastError { Section("LAST ERROR") { Text(e).foregroundStyle(.red) } }
            }.navigationTitle("Diagnostics")
        }
    }
}

private struct DiagnosticRow: View {
    let title: String; let ok: Bool; let detail: String
    init(_ title: String, ok: Bool, detail: String) { self.title=title; self.ok=ok; self.detail=detail }
    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
