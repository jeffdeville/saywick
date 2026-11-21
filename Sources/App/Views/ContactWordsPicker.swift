import SwiftUI
import ContactsUI

/// The system picker shares only contacts the user selects; no address-book scan.
struct ContactWordsPicker: UIViewControllerRepresentable {
    var onSelect: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactGivenNameKey, CNContactFamilyNameKey]
        return picker
    }
    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactWordsPicker
        init(parent: ContactWordsPicker) { self.parent = parent }
        nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            let names = contacts.flatMap { contact in
                [contact.givenName, contact.familyName, [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")]
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            Task { @MainActor in
                parent.onSelect(names)
                parent.dismiss()
            }
        }
        nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            Task { @MainActor in parent.dismiss() }
        }
    }
}
