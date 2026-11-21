import SwiftUI
import VoiceKeyboardCore

struct DictateView: View {
    @Bindable var model: AppModel
    let viewHistory: () -> Void
    private var status: String {
        switch model.phase {
        case .preparing: "Getting microphone ready…"
        case .listening: "Listening"
        case .finalizing: "Finishing…"
        case .failed: "Microphone needs attention"
        default: model.isKeyboardSessionActive ? "Microphone ready" : "Microphone off"
        }
    }
    private var currentText: String {
        guard model.currentResultSession == model.recorder.sessionID else { return "" }
        return model.processedText.isEmpty ? model.transcript : model.processedText
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Button {
                    Task {
                        if model.canStop { await model.stopRecording() }
                        else { await model.startRecording() }
                    }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: model.canStop ? "mic.circle.fill" : "mic.circle")
                            .font(.system(size: 68))
                            .foregroundStyle(model.canStop ? Color.green : model.isKeyboardSessionActive ? .secondary : .red)
                        Text(model.canStop ? "Stop dictation" : model.isKeyboardSessionActive ? "Start next dictation" : "Start dictation")
                            .font(.title3.weight(.semibold))
                    }
                }
                .disabled(!model.canStop && (model.isBusy || model.history.isWorking))
                .accessibilityIdentifier(model.canStop ? "stopDictation" : "startDictation")
                Text(status).font(.headline).accessibilityIdentifier("micStatus")
                if model.phase == .preparing, let progress = model.preparationProgress { ProgressView(value: progress) }
                if model.canStop && model.keyboardOrigin {
                    Text("Return to your app and keep talking.")
                } else if model.phase == .failed || model.recorder.templateFallback != nil || model.phase == .preparing {
                    Text(model.statusMessage).font(.callout)
                } else if model.currentResultSession == model.recorder.sessionID && !model.isBusy {
                    Text(model.statusMessage).font(.callout)
                } else if let deadline = model.keyboardSessionExpiresAt {
                    Text("Ready for another dictation until \(deadline, style: .time).").font(.callout)
                }
                if model.canStop {
                    Menu("Recording options") {
                        Button("Restart dictation") { model.restartTranscript() }
                        Button("Cancel dictation", role: .destructive) { Task { await model.cancelRecording() } }
                    }
                }
                if model.isKeyboardSessionActive {
                    Button("End microphone session") { Task { await model.endKeyboardSession() } }
                }
                if !currentText.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.canStop ? "Live draft" : model.phase == .failed ? "Recovered text" : model.recorder.restoredEntryID == nil ? "Just dictated" : "From History").font(.headline)
                        Text(currentText).textSelection(.enabled).accessibilityIdentifier("transcriptText")
                        if !model.processedText.isEmpty && !model.isBusy {
                            HStack {
                                Button("Copy text") { model.copyResult() }
                                Spacer()
                                Button("View in History", action: viewHistory)
                                Spacer()
                                Button("Clear") { model.clear() }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.keyboardVerified && !model.isBusy {
                    NavigationLink("Set up the keyboard") { KeyboardSetupSettings(model: model) }
                }
            }.padding(24).frame(maxWidth: .infinity)
        }
    }
}
