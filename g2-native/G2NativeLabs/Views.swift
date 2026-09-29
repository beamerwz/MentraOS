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
                    LabeledContent("Mic armed", value: g2.micArmed ? "Yes" : "No")
                    LabeledContent("Audio packets", value: "\(g2.audioPackets)")
                    LabeledContent("Audio bytes", value: "\(g2.audioBytes)")
                    LabeledContent("PCM chunks", value: "\(g2.pcmChunks)")
                    LabeledContent("PCM bytes", value: "\(g2.pcmBytes)")
                    LabeledContent("PCM RMS", value: String(format: "%.4f", g2.pcmRMS))
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
    @EnvironmentObject var g2: G2Transport
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("Import folder or .tar.bz2", systemImage: "square.and.arrow.down")
                    }
                    .disabled(registry.isImporting)

                    if registry.isImporting {
                        ProgressView(value: registry.importProgress)
                        Text("\(Int(registry.importProgress * 100))%")
                            .font(.caption.monospacedDigit())
                    }

                    Text(registry.importMessage)
                        .font(.caption)
                        .foregroundStyle(registry.importMessage.contains("ERROR") ? .red : .secondary)
                } header: {
                    Text("ONE MODEL REGISTRY")
                } footer: {
                    Text("Archives are extracted inside G2 LABS. You do not need to unpack .tar.bz2 in the Files app.")
                }

                Section("Installed") {
                    if registry.models.isEmpty {
                        Text("No models")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(registry.models) { model in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name).font(.headline)
                                    Text(model.family.rawValue)
                                        .font(.subheadline)
                                }
                                Spacer()
                                if registry.activeID == model.id {
                                    Label("ACTIVE", systemImage: "checkmark.circle.fill")
                                        .font(.caption.bold())
                                        .foregroundStyle(.green)
                                }
                            }

                            Text(model.validationMessage)
                                .font(.caption)
                                .foregroundStyle(model.validated ? .green : .orange)

                            if model.validated {
                                Button {
                                    registry.markActive(model)
                                    g2.activateModel(model, directory: model.location)
                                } label: {
                                    Label(
                                        registry.activeID == model.id ? "Reload model" : "Activate model",
                                        systemImage: "waveform.badge.mic"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            registry.delete(registry.models[index])
                        }
                    }
                }

                Section("LIVE ASR") {
                    LabeledContent("State", value: g2.asr.state.label)
                    if !g2.asr.partialText.isEmpty {
                        Text(g2.asr.partialText)
                            .font(.title3)
                    } else if !g2.asr.finalText.isEmpty {
                        Text(g2.asr.finalText)
                            .font(.title3)
                    }
                }
            }
            .navigationTitle("Models")
        }
        .sheet(isPresented: $importing) {
            NativeModelDocumentPicker { result in
                importing = false
                switch result {
                case .success(let url):
                    registry.importModel(url)
                case .failure(let error):
                    registry.importMessage = "IMPORT ERROR: \(error.localizedDescription)"
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            // Do not touch the BLE/audio session merely because the user opened Models.
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
                    DiagnosticRow(
                        "G2 mic session",
                        ok: g2.micArmed,
                        detail: g2.micArmed ? "EvenHub page live • audio OFF→ON sent" : "Waiting for page + mic arm"
                    )
                    DiagnosticRow(
                        "PCM decode",
                        ok: g2.pcmChunks > 0,
                        detail: "\(g2.pcmChunks) chunks / \(g2.pcmBytes) bytes • RMS \(String(format: "%.4f", g2.pcmRMS))"
                    )
                    DiagnosticRow(
                        "ASR recognizer",
                        ok: g2.asr.state.isReady,
                        detail: g2.asr.state.label + " • decode passes \(g2.asr.decodePasses)"
                    )
                    DiagnosticRow(
                        "Caption display",
                        ok: g2.captionUpdates > 0,
                        detail: "\(g2.captionUpdates) text update(s) sent to G2"
                    )
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
