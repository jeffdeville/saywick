import UIKit
import VoiceKeyboardCore

final class KeyboardViewController: UIInputViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let transcriptLabel = UILabel()
    private let stopButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let restartButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private var timer: Timer?
    private var lastRevision = -1
    private var currentSnapshot: SharedSessionSnapshot?
    private var store: SharedContainerStore?
    private var insertedText: String?
    private var insertedContext: String?
    private var insertedDocument: UUID?
    private var deleteTimer: Timer?
    private var cursorOffset: CGFloat = 0
    private lazy var undoButton = makeButton(title: "Undo insertion", action: #selector(undoInsertion))

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()

        do {
            store = try SharedContainerStore()
            refreshSnapshot()
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: 0.2,
            target: self,
            selector: #selector(refreshSnapshot),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer!, forMode: .common)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
        deleteTimer?.invalidate(); deleteTimer = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
    }

    private lazy var nextKeyboardButton: UIButton = makeButton(
        title: "🌐",
        action: #selector(nextKeyboard)
    )

    private func configureView() {
        view.backgroundColor = UIColor.systemBackground
        view.heightAnchor.constraint(equalToConstant: 318).isActive = true

        titleLabel.text = "Saywick"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.text = hasFullAccess
            ? "Start a recording in the app"
            : "Enable Full Access to use the shared transcript"

        transcriptLabel.font = .preferredFont(forTextStyle: .body)
        transcriptLabel.numberOfLines = 3
        transcriptLabel.text = "No transcript yet"

        stopButton.configuration = .filled()
        stopButton.configuration?.title = "Stop & Insert"
        stopButton.configuration?.image = UIImage(systemName: "stop.circle")
        stopButton.configuration?.imagePadding = 6
        stopButton.addTarget(self, action: #selector(stopAndInsert), for: .touchUpInside)

        insertButton.configuration = .bordered()
        insertButton.configuration?.title = "Insert Latest"
        insertButton.addTarget(self, action: #selector(insertLatest), for: .touchUpInside)

        restartButton.configuration = .bordered()
        restartButton.configuration?.title = "Restart"
        restartButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
        restartButton.configuration?.imagePadding = 4
        restartButton.addTarget(self, action: #selector(restartTranscript), for: .touchUpInside)

        clearButton.configuration = .bordered()
        clearButton.configuration?.title = "Clear"
        clearButton.configuration?.image = UIImage(systemName: "xmark.circle")
        clearButton.configuration?.imagePadding = 4
        clearButton.addTarget(self, action: #selector(clearTranscript), for: .touchUpInside)

        let openButton = makeButton(title: "Open Recorder", action: #selector(openRecorder))
        let deleteButton = makeButton(title: "⌫", action: #selector(deleteBackward))
        deleteButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:))))
        let spaceButton = makeButton(title: "space", action: #selector(insertSpace))
        spaceButton.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveCursor(_:))))
        let returnButton = makeButton(title: "return", action: #selector(insertReturn))

        let heading = UIStackView(arrangedSubviews: [titleLabel, UIView(), openButton])
        heading.axis = .horizontal
        heading.spacing = 8
        heading.alignment = .center

        let voiceControls = UIStackView(arrangedSubviews: [stopButton, insertButton])
        voiceControls.axis = .horizontal
        voiceControls.distribution = .fillEqually
        voiceControls.spacing = 8

        let sessionControls = UIStackView(arrangedSubviews: [restartButton, clearButton, undoButton])
        sessionControls.axis = .horizontal
        sessionControls.distribution = .fillEqually
        sessionControls.spacing = 8

        let typingControls = UIStackView(
            arrangedSubviews: [nextKeyboardButton, deleteButton, spaceButton, returnButton]
        )
        typingControls.axis = .horizontal
        typingControls.distribution = .fillProportionally
        typingControls.spacing = 8

        let root = UIStackView(
            arrangedSubviews: [
                heading,
                statusLabel,
                transcriptLabel,
                voiceControls,
                sessionControls,
                typingControls,
            ]
        )
        root.axis = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
            voiceControls.heightAnchor.constraint(equalToConstant: 44),
            sessionControls.heightAnchor.constraint(equalToConstant: 38),
            typingControls.heightAnchor.constraint(equalToConstant: 42),
            spaceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
        ])
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = .bordered()
        button.configuration?.title = title
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func refreshSnapshot() {
        undoButton.isEnabled = canUndoInsertion
        guard hasFullAccess else {
            statusLabel.text = "Enable Full Access in Settings > General > Keyboard > Keyboards"
            stopButton.isEnabled = false
            insertButton.isEnabled = false
            restartButton.isEnabled = false
            clearButton.isEnabled = false
            return
        }

        do {
            guard let snapshot = try store?.readSnapshot(),
                  snapshot.revision != lastRevision else { return }
            lastRevision = snapshot.revision
            currentSnapshot = snapshot
            statusLabel.text = snapshot.message
            let displayText = snapshot.phase == .ready
                ? snapshot.insertableText
                : snapshot.liveText
            transcriptLabel.text = displayText.isEmpty ? "No transcript yet" : displayText
            stopButton.isEnabled = snapshot.phase == .listening
            insertButton.isEnabled = snapshot.phase == .ready && !snapshot.insertableText.isEmpty
            restartButton.isEnabled = snapshot.phase == .listening
            clearButton.isEnabled = snapshot.phase == .listening || !snapshot.liveText.isEmpty || !snapshot.insertableText.isEmpty

            if snapshot.phase == .ready,
               snapshot.shouldAutoInsert,
               !snapshot.insertableText.isEmpty,
               !hasInserted(snapshot.sessionID) {
                insert(snapshot.insertableText)
                rememberInserted(snapshot.sessionID)
                consume(snapshot)
            }
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    @objc private func stopAndInsert() {
        do {
            try store?.write(command: VoiceCommand(kind: .stopAndInsert))
            statusLabel.text = "Finishing in the recorder app…"
            stopButton.isEnabled = false
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    @objc private func insertLatest() {
        guard let snapshot = currentSnapshot,
              !snapshot.insertableText.isEmpty else { return }
        insert(snapshot.insertableText)
        rememberInserted(snapshot.sessionID)
        consume(snapshot)
    }

    @objc private func restartTranscript() {
        send(.restart, status: "Restarting transcript…")
    }

    @objc private func clearTranscript() {
        guard let snapshot = currentSnapshot else {
            send(.clear, status: "Clearing transcript…")
            return
        }

        do {
            // Once recording has stopped, iOS may suspend the containing app.
            // Clear the shared file here as well so the button responds now.
            if snapshot.phase != .listening {
                try store?.clearSnapshot(ifSessionID: snapshot.sessionID)
                clearDisplayedSnapshot(status: "Cleared")
            }
            try store?.write(command: VoiceCommand(kind: .clear))
            if snapshot.phase == .listening {
                statusLabel.text = "Clearing transcript…"
            }
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    private func send(_ command: VoiceCommandKind, status: String) {
        do {
            try store?.write(command: VoiceCommand(kind: command))
            statusLabel.text = status
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    private func consume(_ snapshot: SharedSessionSnapshot) {
        do {
            try store?.clearSnapshot(ifSessionID: snapshot.sessionID)
            try store?.write(command: VoiceCommand(kind: .clear))
            clearDisplayedSnapshot(status: "Inserted and cleared")
        } catch {
            statusLabel.text = "Inserted, but could not clear: \(error.localizedDescription)"
        }
    }

    private func clearDisplayedSnapshot(status: String) {
        currentSnapshot = nil
        transcriptLabel.text = "No transcript yet"
        statusLabel.text = status
        stopButton.isEnabled = false
        insertButton.isEnabled = false
        restartButton.isEnabled = false
        clearButton.isEnabled = false
    }

    private func insert(_ text: String) {
        let prefix: String
        if let context = textDocumentProxy.documentContextBeforeInput,
           !context.isEmpty,
           let last = context.last,
           !last.isWhitespace,
           !",.;:!?)]}".contains(text.first ?? " ") {
            prefix = " "
        } else {
            prefix = ""
        }
        let inserted = prefix + text
        textDocumentProxy.insertText(inserted)
        insertedText = inserted
        insertedContext = textDocumentProxy.documentContextBeforeInput
        insertedDocument = textDocumentProxy.documentIdentifier
        undoButton.isEnabled = canUndoInsertion
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func openRecorder() {
        guard let url = URL(string: "saywick://start") else { return }
        extensionContext?.open(url, completionHandler: nil)
        statusLabel.text = "If the app does not open, launch Saywick or use its Action Button shortcut"
    }

    @objc private func nextKeyboard() {
        advanceToNextInputMode()
    }

    @objc private func deleteBackward() {
        insertedText = nil
        textDocumentProxy.deleteBackward()
    }

    @objc private func insertSpace() {
        insertedText = nil
        textDocumentProxy.insertText(" ")
    }

    @objc private func insertReturn() {
        insertedText = nil
        textDocumentProxy.insertText("\n")
    }

    private func hasInserted(_ id: UUID) -> Bool {
        insertedDefaults?.string(forKey: "lastInsertedSession") == id.uuidString
    }

    private func rememberInserted(_ id: UUID) {
        insertedDefaults?.set(id.uuidString, forKey: "lastInsertedSession")
    }

    private var insertedDefaults: UserDefaults? {
        guard let identifier = Bundle.main.object(
            forInfoDictionaryKey: "AppGroupIdentifier"
        ) as? String else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    private var canUndoInsertion: Bool {
        guard let insertedText, !insertedText.isEmpty, let context = textDocumentProxy.documentContextBeforeInput else { return false }
        return insertedDocument == textDocumentProxy.documentIdentifier && context == insertedContext && context.hasSuffix(insertedText)
    }
    @objc private func undoInsertion() {
        guard canUndoInsertion, let insertedText else { statusLabel.text = "Text changed; undo is unavailable. Recover the original in History."; return }
        for _ in insertedText { textDocumentProxy.deleteBackward() }
        self.insertedText = nil; undoButton.isEnabled = false
        statusLabel.text = "Insertion undone; recording remains in History"
    }
    @objc private func holdDelete(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            deleteBackward(); deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(timeInterval: 0.09, target: self, selector: #selector(deleteBackward), userInfo: nil, repeats: true)
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            deleteTimer?.invalidate(); deleteTimer = nil
        }
    }
    @objc private func moveCursor(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { cursorOffset = 0; insertedText = nil }
        let position = gesture.translation(in: gesture.view).x
        let steps = Int((position - cursorOffset) / 12)
        if steps != 0 { textDocumentProxy.adjustTextPosition(byCharacterOffset: steps); cursorOffset += CGFloat(steps) * 12 }
    }
}
