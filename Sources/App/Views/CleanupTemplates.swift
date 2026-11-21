import Foundation
import Observation
import SwiftUI

struct CleanupTemplate: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var prompt = ""
    var modelID: String?
}

@Observable
final class CleanupTemplates {
    private(set) var items: [CleanupTemplate] = []
    private(set) var loadError: String?
    private let defaults: UserDefaults
    private let key = "namedCleanupTemplates"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.object(forKey: key) {
            guard let bytes = data as? Data,
                  let saved = try? JSONDecoder().decode([CleanupTemplate].self, from: bytes) else {
                loadError = "Saved templates could not be read."
                return
            }
            items = saved
        }
    }

    func save(_ draft: CleanupTemplate) throws {
        var value = draft
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TemplateError.empty
        }
        guard !items.contains(where: { $0.id != value.id && $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) else {
            throw TemplateError.duplicate
        }
        var updated = items
        if let index = items.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
        else { updated.append(value) }
        try persist(updated)
    }

    func remove(_ id: UUID) throws { try persist(items.filter { $0.id != id }) }

    private func persist(_ updated: [CleanupTemplate]) throws {
        guard loadError == nil else { throw TemplateError.unreadable }
        defaults.set(try JSONEncoder().encode(updated), forKey: key)
        items = updated
    }

    private enum TemplateError: LocalizedError {
        case empty, duplicate, unreadable
        var errorDescription: String? {
            switch self {
            case .empty: "Enter a name and a prompt."
            case .duplicate: "Choose a different template name."
            case .unreadable: "Saved templates could not be read."
            }
        }
    }
}


struct CleanupTemplateSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        List {
            if let message = model.templates.loadError { Text(message) }
            ForEach(model.templates.items) { item in
                NavigationLink { TemplateEditor(model: model, draft: item) } label: {
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text(item.modelID ?? "Use my OpenAI default").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink("New template") { TemplateEditor(model: model, draft: CleanupTemplate()) }
        }.navigationTitle("Templates")
    }
}

private struct TemplateEditor: View {
    let model: AppModel
    @State var draft: CleanupTemplate
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section("Name") { TextField("Name", text: $draft.name) }
            Section("Prompt") { TextField("What should this template do?", text: $draft.prompt, axis: .vertical).lineLimit(4...14) }
            Section {
                NavigationLink {
                    ModelPicker(selected: $draft.modelID, inherited: model.defaultTemplateModel)
                } label: { LabeledContent("Cleanup model", value: draft.modelID ?? "Use my default") }
            } header: { Text("OpenAI") } footer: { Text("Applies only when you select this template for a recording.") }
            Button("Save template") {
                do { try model.templates.save(draft); dismiss() } catch { self.error = error.localizedDescription }
            }
            if model.templates.items.contains(where: { $0.id == draft.id }) {
                Button("Delete template", role: .destructive) {
                    do { try model.templates.remove(draft.id); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Edit template")
    }
}
