import SwiftUI
import VoiceKeyboardCore

struct MyWordsSettings: View {
    @Bindable var model: AppModel
    @State private var draft: WordDraft?
    @State private var contacts = false
    @State private var review = false
    @State private var names: [String] = []
    private var lines: [String] { model.customWordsText.components(separatedBy: .newlines) }

    var body: some View {
        List {
            Toggle("Use my words", isOn: $model.customWordsEnabled)
            ForEach([false, true], id: \.self) { replacement in
                Section(replacement ? "Exact replacements" : "Preferred spellings") {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty && line.contains("=") == replacement {
                            Button(line.replacingOccurrences(of: "=", with: "→")) {
                                draft = WordDraft(index: index, line: line, replacement: replacement)
                            }.swipeActions {
                                Button("Delete", role: .destructive) {
                                    var updated = lines
                                    updated.remove(at: index)
                                    model.customWordsText = updated.joined(separator: "\n")
                                }
                            }
                        }
                    }
                    Button(replacement ? "Add replacement" : "Add word") { draft = WordDraft(replacement: replacement) }
                }
            }
            Section {
                Button("Add names from Contacts") { contacts = true }.disabled(model.customWordsError != nil)
                if let error = model.customWordsError { Text(error) }
            }
        }.navigationTitle("My words")
        .sheet(item: $draft) { value in WordEditor(model: model, draft: value) }
        .sheet(isPresented: $contacts, onDismiss: { review = !names.isEmpty }) {
            ContactWordsPicker { selected in
                var seen = Set(((try? CustomVocabulary(model.customWordsText).entries) ?? []).map { $0.heard.lowercased() })
                names = selected.filter { !$0.contains("=") && !$0.contains(where: \.isNewline) && seen.insert($0.lowercased()).inserted }
            }
        }
        .sheet(isPresented: $review, onDismiss: { names = [] }) {
            NavigationStack {
                List(names, id: \.self) { Text($0) }.navigationTitle("Review names")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { review = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add names") {
                                model.customWordsText = ([model.customWordsText] + names).filter { !$0.isEmpty }.joined(separator: "\n")
                                review = false
                            }
                        }
                    }
            }
        }
    }
}

private struct WordDraft: Identifiable {
    let id = UUID()
    var index: Int?
    let replacement: Bool
    var heard: String
    var preferred: String
    init(index: Int? = nil, line: String = "", replacement: Bool) {
        self.index = index
        self.replacement = replacement
        let parts = line.components(separatedBy: "=")
        heard = replacement ? parts[0].trimmingCharacters(in: .whitespaces) : ""
        preferred = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
    }
}

private struct WordEditor: View {
    let model: AppModel
    @State var draft: WordDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if draft.replacement { TextField("When I say", text: $draft.heard) }
                TextField("Preferred spelling", text: $draft.preferred)
                if let error { Text(error).foregroundStyle(.red) }
            }.autocorrectionDisabled()
            .navigationTitle(draft.replacement ? "Exact replacement" : "Preferred spelling")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }
    private func save() {
        let fields = (draft.replacement ? [draft.heard, draft.preferred] : [draft.preferred]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.contains(where: \.isNewline) }) else {
            error = CustomVocabulary.CorrectionError.invalidFields.localizedDescription
            return
        }
        var lines = model.customWordsText.components(separatedBy: .newlines)
        let line = fields.joined(separator: " = ")
        if let index = draft.index { lines[index] = line } else { lines.append(line) }
        let updated = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        do { _ = try CustomVocabulary(updated); model.customWordsText = updated; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
