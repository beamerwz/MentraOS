import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "captions.bubble.fill") }
            ModelsView()
                .tabItem { Label("Models", systemImage: "shippingbox.fill") }
            DiagnosticsView()
                .tabItem { Label("Diagnose", systemImage: "waveform.path.ecg") }
        }
        .tint(Color(red: 0.72, green: 0.42, blue: 1.0))
    }
}

private struct LiveView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    g2Card
                    pipelineCard
                    transcriptCard
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("G2 LABS")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STANDALONE")
                .font(.caption.bold())
                .foregroundStyle(.purple)
            Text("Direct speech pipeline")
                .font(.largeTitle.bold())
            Text("No Mentra engine · no miniapps · no cloud routing")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var g2Card: some View {
        panel {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Even G2").font(.headline)
                    Text(app.g2.status).foregroundStyle(.secondary)
                    if !app.g2.discoveredSerial.isEmpty {
                        Text(app.g2.discoveredSerial).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Circle()
                    .fill(app.g2.connected ? .green : .orange)
                    .frame(width: 12, height: 12)
            }
            Button(app.g2.connected ? "Reconnect G2" : "Scan + Connect G2") {
                app.connectG2()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var pipelineCard: some View {
        panel {
            Text("CAPTION PIPELINE").font(.headline)
            Picker("Input", selection: Binding(
                get: { app.inputSource },
                set: { app.switchInput($0) }
            )) {
                ForEach(AppModel.InputSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Picker("Model", selection: Binding(
                get: { app.models.selectedID ?? "" },
                set: { app.models.selectedID = $0 }
            )) {
                ForEach(app.models.installed) { model in
                    Text(model.name).tag(model.id)
                }
            }

            HStack {
                Text("Audio")
                ProgressView(value: app.diagnostics.audioLevel, total: 1)
            }

            Text(app.status)
                .font(.footnote)
                .foregroundStyle(app.diagnostics.lastError.isEmpty ? .secondary : .orange)

            Button(app.isRunning ? "Stop captions" : "Start captions") {
                app.isRunning ? app.stop() : app.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isRunning ? .red : .purple)
        }
    }

    private var transcriptCard: some View {
        panel {
            Text("LIVE TEXT").font(.headline)
            Text(app.liveText.isEmpty ? "Say something…" : app.liveText)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                .textSelection(.enabled)
            if !app.finalLines.isEmpty {
                Divider()
                ForEach(Array(app.finalLines.suffix(5).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.08, green: 0.065, blue: 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.purple.opacity(0.25)))
    }
}

private struct ModelsView: View {
    @EnvironmentObject var app: AppModel
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Installed") {
                    if app.models.installed.isEmpty {
                        Text("No models installed").foregroundStyle(.secondary)
                    }
                    ForEach(app.models.installed) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model.name).font(.headline)
                                Spacer()
                                if app.models.selectedID == model.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                                }
                            }
                            Text(model.kind.displayName).font(.caption).foregroundStyle(.secondary)
                            Text(model.language).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { app.models.selectedID = model.id }
                    }
                }

                Section("Known presets") {
                    ForEach(ModelPreset.all) { preset in
                        Button {
                            Task { await app.models.install(preset) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name).font(.headline)
                                Text(preset.notes).font(.caption).foregroundStyle(.secondary)
                                Text(preset.kind.displayName).font(.caption2).foregroundStyle(.purple)
                            }
                        }
                    }
                }

                Section("Custom model") {
                    Button("Import extracted model folder") { importing = true }
                    Text("The importer detects transducer, NeMo CTC, Zipformer2 CTC and Paraformer layouts. Arbitrary ONNX files are rejected with a diagnosis instead of being guessed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Activity") {
                    Text(app.models.activity)
                    ProgressView(value: app.models.progress, total: 1)
                }
            }
            .navigationTitle("Models")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await app.models.importFolder(url) }
                } else if case .failure(let error) = result {
                    app.diagnostics.error("models", error.localizedDescription)
                }
            }
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject var app: AppModel
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Pipeline") {
                    metric("BLE", app.diagnostics.bleState)
                    metric("Left lens", app.diagnostics.leftConnected ? "connected" : "not connected")
                    metric("Right lens", app.diagnostics.rightConnected ? "connected" : "not connected")
                    metric("LC3 frames", "\(app.diagnostics.lc3Frames)")
                    metric("PCM frames", "\(app.diagnostics.pcmFrames)")
                    metric("Recognizer feeds", "\(app.diagnostics.recognizerFrames)")
                    metric("Partials", "\(app.diagnostics.partials)")
                    metric("Finals", "\(app.diagnostics.finals)")
                    metric("G2 display writes", "\(app.diagnostics.displayWrites)")
                    metric("Audio level", String(format: "%.3f", app.diagnostics.audioLevel))
                    metric("Decode RTF", app.diagnostics.decodeRtf.map { String(format: "%.3f", $0) } ?? "—")
                    metric("First partial", app.diagnostics.lastPartialLatencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
                }

                if !app.diagnostics.lastError.isEmpty {
                    Section("Last error") {
                        Text(app.diagnostics.lastError).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }

                Section("Trace") {
                    ForEach(Array(app.diagnostics.events.suffix(120).reversed())) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.stage.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(.purple)
                            Text(event.message).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                Section {
                    Button("Generate diagnosis JSON") {
                        exportURL = app.diagnostics.exportURL()
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share diagnosis", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Reset counters") { app.diagnostics.resetCounters() }
                }
            }
            .navigationTitle("Diagnostics")
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
