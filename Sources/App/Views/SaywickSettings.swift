import AVFoundation
import SwiftUI
import VoiceKeyboardCore

struct SaywickSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        List {
            Section {
                NavigationLink("Text cleanup") { TextCleanupSettings(model: model) }
                NavigationLink("Templates") { CleanupTemplateSettings(model: model) }
                NavigationLink("My words") { MyWordsSettings(model: model) }
            }
            Section {
                NavigationLink("OpenAI connection") { OpenAISettings(model: model) }
                NavigationLink("Keyboard setup & help") { KeyboardSetupSettings(model: model) }
                NavigationLink("Privacy & diagnostics") { PrivacySettings(model: model) }
            }
        }.navigationTitle("Settings")
    }
}

private struct TextCleanupSettings: View {
    @Bindable var model: AppModel
    private var processor: Binding<PostProcessorID> {
        Binding(get: { model.selectedPostProcessorID == .foundationModelsStructured ? .foundationModels : model.selectedPostProcessorID },
                set: { model.selectedPostProcessorID = $0 })
    }
    var body: some View {
        Form {
            Section("Regular Polish") {
                Picker("Process text with", selection: processor) {
                    Text("Off").tag(PostProcessorID.none)
                    Text("Basic local rules").tag(PostProcessorID.rules)
                    Text("Apple · on device").tag(PostProcessorID.foundationModels)
                    Text("OpenAI").tag(PostProcessorID.openAILuna)
                }
                if processor.wrappedValue == .openAILuna {
                    Text("OpenAI bills your account for Polish. Saywick sends the transcript, your formatting preference, and relevant custom words. Audio stays on this iPhone.")
                        .font(.footnote)
                }
                if processor.wrappedValue == .foundationModels {
                    Picker("Format", selection: $model.selectedPostProcessorID) {
                        Text("Sentences").tag(PostProcessorID.foundationModels)
                        Text("Paragraphs and bullets").tag(PostProcessorID.foundationModelsStructured)
                    }
                }
                if model.selectedPostProcessorID.usesLanguageModel {
                    TextField("Optional formatting preference", text: $model.customCleanupInstructions, axis: .vertical)
                }
            }.disabled(model.isBusy)
            Section("Example") {
                LabeledContent("You say", value: "i need bread milk and eggs")
                switch model.selectedPostProcessorID {
                case .none: LabeledContent("With cleanup off", value: "i need bread milk and eggs")
                case .rules: LabeledContent("Basic rules", value: "I need bread milk and eggs.")
                case .foundationModelsStructured: LabeledContent("With Polish", value: "I need:\n• bread\n• milk\n• and eggs")
                default: LabeledContent("With Polish", value: "I need bread, milk, and eggs.")
                }
            }
        }.navigationTitle("Text cleanup")
    }
}

struct KeyboardSetupSettings: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSteps = false
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var downloaded = false
    var body: some View {
        Form {
            Section("Keyboard setup") {
                if model.keyboardVerified { LabeledContent("Keyboard dictation", value: "Previously verified") }
                if !model.keyboardVerified || showSteps || permission == .denied {
                    LabeledContent("Microphone access", value: permission == .authorized ? "Allowed" : "Needs setup")
                    LabeledContent("On-device speech model", value: downloaded ? "Downloaded" : "Needs setup")
                    if permission == .notDetermined || !downloaded {
                        Button("Prepare for dictation") {
                            Task { await model.prepareBackgroundDictation(); await refresh() }
                        }.disabled(model.isBusy || model.history.isWorking || model.isKeyboardSessionActive)
                        Text(model.statusMessage).font(.footnote)
                    }
                    Text("In iPhone Settings, add Saywick under General → Keyboard → Keyboards and turn on Allow Full Access. In a text field, choose Saywick and try Stop & Insert.")
                    Button("Open Settings") { model.openKeyboardSettings() }
                } else {
                    Button("Check setup again") { showSteps = true; Task { await refresh() } }
                }
            }
            Section("Between dictations") {
                Toggle("Keep microphone ready", isOn: $model.keepKeyboardReady)
                    .disabled(model.isBusy || model.isKeyboardSessionActive)
                Text("Start another dictation from the keyboard for up to two minutes after you stop.").font(.footnote)
            }
            Section("Help") {
                DisclosureGroup("Using the Action Button") {
                    Text("In Settings → Action Button → Shortcut, choose Start Saywick dictation. Allow Live Activities for Saywick. The shortcut starts listening after microphone and speech-model setup.")
                }
                DisclosureGroup("Keyboard missing in another app") {
                    Text("Hold the globe in a text field and choose Saywick. Secure fields and some apps use the system keyboard.")
                }
                DisclosureGroup("About speech recognition") {
                    Text("Parakeet transcribes English on this iPhone. First use downloads its 731 MB speech model.")
                    Link("Model credits and license", destination: URL(string: "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf")!)
                }
            }
        }.navigationTitle("Keyboard setup & help")
        .task(id: scenePhase) { if scenePhase == .active { await refresh() } }
    }
    private func refresh() async {
        permission = AVCaptureDevice.authorizationStatus(for: .audio)
        downloaded = await ParakeetModelStore.shared.hasDownloadedModel
    }
}
