import SwiftUI
import UniformTypeIdentifiers

struct PairingView: View {
    @EnvironmentObject var g2: G2Transport

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.04, blue: 0.12), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer(minLength: 32)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("G2 LABS")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                        Text("NATIVE PAIRING")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.purple)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(.purple)
                            Text(g2.pairingStage.title)
                                .font(.title2.bold())
                        }
                        Text(g2.pairingStage.detail)
                            .foregroundStyle(.secondary)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                    if !g2.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("FOUND G2")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            ForEach(g2.candidates) { device in
                                Button {
                                    g2.pair(serial: device.serial)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "eyeglasses")
                                            .font(.title2)
                                            .foregroundStyle(.purple)
                                            .frame(width: 42, height: 42)
                                            .background(Color.purple.opacity(0.12), in: Circle())

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(device.serial)
                                                .foregroundStyle(.primary)
                                                .font(.headline)
                                            Text(device.complete ? "Left + right ready" : "Waiting for both lenses")
                                                .foregroundStyle(device.complete ? .green : .orange)
                                                .font(.caption)
                                        }

                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(18)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                }
                                .disabled(!device.complete)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("How pairing works", systemImage: "bolt.horizontal.circle")
                            .font(.headline)
                        Text("G2 LABS finds both physical lenses, connects LEFT + RIGHT, authenticates both sides, sets the pipe role, syncs time, then marks the glasses ready.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Button {
                        g2.scan()
                    } label: {
                        Label("Scan again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)

                    if case .failed = g2.pairingStage {
                        Button(role: .destructive) {
                            g2.forgetAndRescan()
                        } label: {
                            Text("Forget saved G2 and retry")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

struct ConnectionView: View {
    @EnvironmentObject var g2: G2Transport

    var body: some View {
        NavigationStack {
            List {
                Section("DIRECT G2") {
                    LabeledContent("Bluetooth", value: g2.bluetoothState)
                    LabeledContent("Serial", value: g2.connectedSerial ?? "—")
                    LabeledContent("Connected", value: g2.connectedName ?? "No")
                }

                Section("RAW AUDIO PROOF") {
                    LabeledContent("Audio packets", value: "\(g2.audioPackets)")
                    LabeledContent("Audio bytes", value: "\(g2.audioBytes)")
                    LabeledContent(
                        "Last audio",
                        value: g2.lastAudioAt?.formatted(date: .omitted, time: .standard) ?? "Never"
                    )
                }

                Section {
                    Button(role: .destructive) {
                        g2.forgetAndRescan()
                    } label: {
                        Text("Forget G2 / Pair another")
                    }
                }
            }
            .navigationTitle("G2 LABS Native")
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
                } header: {
                    Text("ONE MODEL REGISTRY")
                }

                Section("Installed") {
                    if registry.models.isEmpty {
                        Text("No models")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(registry.models) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name).font(.headline)
                            Text(model.family.rawValue)
                            Text(model.validationMessage)
                                .font(.caption)
                                .foregroundStyle(model.validated ? .green : .orange)
                        }
                    }
                }
            }
            .navigationTitle("Models")
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                registry.importFolder(url)
            }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var g2: G2Transport

    var body: some View {
        NavigationStack {
            List {
                Section("PIPELINE") {
                    DiagnosticRow(
                        "BLE pair",
                        ok: g2.isReady,
                        detail: g2.connectedSerial ?? g2.pairingStage.detail
                    )
                    DiagnosticRow(
                        "G2 audio packets",
                        ok: g2.audioPackets > 0,
                        detail: "\(g2.audioPackets) packets / \(g2.audioBytes) bytes"
                    )
                    DiagnosticRow("PCM decode", ok: false, detail: "Next gate: LC3 decoder")
                    DiagnosticRow("ASR recognizer", ok: false, detail: "Not started")
                    DiagnosticRow("Caption display", ok: false, detail: "Not started")
                }

                Section("EVENT LOG") {
                    ForEach(Array(g2.events.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let error = g2.lastError {
                    Section("LAST ERROR") {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}

private struct DiagnosticRow: View {
    let title: String
    let ok: Bool
    let detail: String

    init(_ title: String, ok: Bool, detail: String) {
        self.title = title
        self.ok = ok
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
