import SwiftUI

@main
@MainActor
struct LocalVoiceKeyboardApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    await model.monitorKeyboardCommands()
                }
                .task { await model.watchInterruptions() }
                .onOpenURL { url in
                    Task {
                        await model.handleOpenURL(url)
                    }
                }
        }
    }
}
