import SwiftUI

@main
@MainActor
struct LocalVoiceKeyboardApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    await model.startServices()
                    SaywickShortcuts.updateAppShortcutParameters()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: ActivationDiagnostics.shared.record("App became active (caller not provided by iOS)")
                    case .background: ActivationDiagnostics.shared.record("App entered background")
                    case .inactive: break
                    @unknown default: break
                    }
                }
                .onOpenURL { url in
                    Task {
                        await model.handleOpenURL(url)
                    }
                }
        }
    }
}
