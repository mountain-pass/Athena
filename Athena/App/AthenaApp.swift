import SwiftUI

@main
struct AthenaApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.gateway)
                .environmentObject(app.voice)
                .frame(minWidth: 1180, minHeight: 760)
                .background(Theme.bg)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(app.gateway)
                .environmentObject(app.voice)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if app.setupComplete {
                MainView()
            } else {
                SetupWizardView()
            }
        }
    }
}
