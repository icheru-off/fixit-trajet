import SwiftUI

@main
struct FixitTrajetApp: App {
    @StateObject private var config = AppConfig()
    @StateObject private var trips = TripManager()
    @Environment(\.scenePhase) private var phase
    @State private var setupError: String?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(config)
                .environmentObject(trips)
                .tint(Brand.blue)
                .onAppear {
                    trips.attach(config)
                    Task { await trips.resumeIfNeeded() }
                }
                .onOpenURL { url in
                    Task {
                        setupError = await config.handle(url: url)
                        trips.attach(config)
                    }
                }
                .alert("Configuration", isPresented: Binding(get: { setupError != nil }, set: { if !$0 { setupError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(setupError ?? "")
                }
        }
        .onChange(of: phase) { p in
            if p == .active { Task { await trips.flush(force: true) } }
        }
    }
}

enum Brand {
    static let blue = Color(red: 0.078, green: 0.537, blue: 0.769)      // #1489C4
    static let blueDark = Color(red: 0.047, green: 0.427, blue: 0.620)  // #0C6D9E
    static let paper = Color(red: 0.965, green: 0.957, blue: 0.937)     // #F6F4EF
    static let ink = Color(red: 0.067, green: 0.078, blue: 0.071)       // #111412
    static let ok = Color(red: 0.118, green: 0.498, blue: 0.310)        // #1E7F4F
}
