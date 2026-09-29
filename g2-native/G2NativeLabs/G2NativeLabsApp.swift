import SwiftUI

@main
struct G2NativeLabsApp: App {
    @StateObject private var transport = G2Transport()
    @StateObject private var models = ModelRegistry()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(transport)
                .environmentObject(models)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ConnectionView().tabItem { Label("G2", systemImage: "eyeglasses") }
            ModelsView().tabItem { Label("Models", systemImage: "waveform") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .tint(.purple)
    }
}
