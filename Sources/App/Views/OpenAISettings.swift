import SwiftUI

struct OpenAISettings: View {
    @Bindable var model: AppModel
    @State private var key = ""
    @State private var saved = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("API key", value: saved ? "Saved on this iPhone" : "None saved")
                SecureField(saved ? "Replacement API key" : "OpenAI API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save API key") { updateKey(key) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved { Button("Remove API key", role: .destructive) { updateKey("") } }
                if let message { Text(message) }
                Link("Create or manage an API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
            Section {
                NavigationLink {
                    ModelPicker(selected: Binding(get: { model.defaultTemplateModel }, set: { if let value = $0 { model.defaultTemplateModel = value } }), inherited: nil)
                } label: { LabeledContent("Default cleanup model", value: model.defaultTemplateModel) }
            } header: { Text("Templates") } footer: {
                Text("OpenAI bills your account. Choosing an OpenAI template sends its prompt and the finished transcript. Audio stays on this iPhone.")
            }
        }.navigationTitle("OpenAI connection").onAppear { saved = OpenAIKeyStore.read() != nil }
    }
    private func updateKey(_ value: String) {
        do { try OpenAIKeyStore.save(value); saved = OpenAIKeyStore.read() != nil; key = ""; message = saved ? "Key saved." : "Key removed." }
        catch { message = error.localizedDescription }
    }
}

struct ModelPicker: View {
    @Binding var selected: String?
    let inherited: String?
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var inventory: [String] = []
    @State private var loading = false
    @State private var message: String?
    var body: some View {
        Form {
            if let inherited {
                Button("Use my default (\(inherited))") { selected = nil; dismiss() }
            }
            Section("Chat model ID") {
                TextField("Exact OpenAI model ID", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Use model") { selected = input.trimmingCharacters(in: .whitespacesAndNewlines); dismiss() }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                Button(loading ? "Loading…" : "Show models in my account") { Task { await loadModels() } }.disabled(loading)
                if let message { Text(message) }
                ForEach(inventory.filter { input.isEmpty || $0.localizedCaseInsensitiveContains(input) }, id: \.self) { id in
                    Button(id) { selected = id; dismiss() }
                }
            } header: { Text("Account models") } footer: { Text("Choose a text model that supports Chat Completions. Your account may also list models for images, audio, and other tasks.") }
        }.navigationTitle("Cleanup model").onAppear { input = selected ?? "" }
    }
    private func loadModels() async {
        guard let key = OpenAIKeyStore.read() else { message = "Save an API key in OpenAI connection first."; return }
        loading = true; defer { loading = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PostProcessingError.openAIUnavailable }
            struct Inventory: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
            inventory = try JSONDecoder().decode(Inventory.self, from: data).data.map(\.id).sorted()
            input = ""; message = inventory.isEmpty ? "No models returned." : nil
        } catch { message = "Could not load models. Check your key and connection, or enter a model ID." }
    }
}
