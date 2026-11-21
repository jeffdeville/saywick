import Foundation
import Observation
import SwiftUI

struct CleanupTemplate: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var prompt = ""
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
    let catalog: CleanupTemplates
    @State private var draft = CleanupTemplate()
    @State private var error: String?

    var body: some View {
        Form {
            Section("Saved templates") {
                if let message = catalog.loadError { Text(message) }
                ForEach(catalog.items) { item in
                    Button(item.name) { draft = item; error = nil }
                }
                Button("New template") { draft = CleanupTemplate(); error = nil }
            }
            Section("Template") {
                TextField("Name", text: $draft.name)
                TextField("Prompt", text: $draft.prompt, axis: .vertical).lineLimit(3...12)
                Button("Save") {
                    do { try catalog.save(draft); draft = CleanupTemplate(); error = nil }
                    catch { self.error = error.localizedDescription }
                }
                if catalog.items.contains(where: { $0.id == draft.id }) {
                    Button("Delete template", role: .destructive) {
                        do { try catalog.remove(draft.id); draft = CleanupTemplate(); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(catalog.loadError != nil)
        }
        .navigationTitle("Cleanup templates")
    }
}
