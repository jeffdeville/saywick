import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let close = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Saving audio to Saywick…"; label.numberOfLines = 0
        label.textAlignment = .center
        close.isEnabled = false
        close.setTitle("Done", for: .normal)
        close.addTarget(self, action: #selector(done), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, close])
        stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier) }) else {
            label.text = "No supported audio attachment. In Voice Memos, share the Rendered audio file."; close.isEnabled = true; return
        }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { [weak self] url, error in
            let result: String
            do {
                guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 && size <= 1_000_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let ext = url.pathExtension.lowercased()
                guard ["m4a", "wav", "mp3", "aac", "caf", "aif", "aiff", "flac"].contains(ext) else { throw CocoaError(.fileReadUnknown) }
                let inbox = try SharedAudioInbox.directory()
                let target = inbox.appendingPathComponent(UUID().uuidString + "." + ext)
                try FileManager.default.copyItem(at: url, to: target)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                result = "Audio saved locally. Open Saywick → History → Shared audio to import it, then transcribe with Parakeet. Nothing has been uploaded."
            } catch { result = "Could not save audio: \(error.localizedDescription). Try Save to Files, then Import Audio in Saywick." }
            Task { @MainActor in self?.label.text = result; self?.close.isEnabled = true }
        }
    }
    @objc private func done() { extensionContext?.completeRequest(returningItems: nil) }
}
