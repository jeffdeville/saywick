import UIKit
import SwiftUI
import VoiceKeyboardCore

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let transcriptLabel = UILabel()
    private let stopButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let restartButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let keyboardID = UUID()
    private var keyboardIsVisible = false
    private var lastVisibleAt: Date?
    private var lastPresenceWrite = Date.distantPast
    private var timer: Timer?
    private var pendingAction: (command: VoiceCommandKind, date: Date)?
    private var lastRevision = -1
    private var currentSnapshot: SharedSessionSnapshot?
    private var store: SharedContainerStore?
    private var insertedText: String?
    private var insertedContext: String?
    private var insertedDocument: UUID?
    private var deleteTimer: Timer?
    private var cursorOffset: CGFloat = 0
    private var uppercase = false
    private var symbols = false
    private let characterRows = UIStackView()
    private let voicePanel = UIStackView()
    private let typingPanel = UIStackView()
    private let morePanel = UIStackView()
    private var keyboardHeight: NSLayoutConstraint?
    private var launchController: UIHostingController<KeyboardAppLink>?
    private var activationFailure: String?

    private lazy var modeButton = makeButton(title: "ABC", action: #selector(toggleTypingMode))
    private lazy var shiftButton = makeButton(title: "⇧", action: #selector(toggleShift))
    private lazy var symbolsButton = makeButton(title: "123", action: #selector(toggleSymbols))
    private lazy var endSessionButton = makeButton(title: "End", action: #selector(endSession))
    private lazy var undoButton = makeButton(title: "Undo insertion", action: #selector(undoInsertion))

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()

        do {
            if hasFullAccess { store = try SharedContainerStore() }
            refreshSnapshot()
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardIsVisible = true
        typingPanel.isHidden = true
        voicePanel.isHidden = false
        modeButton.configuration?.title = "ABC"
        symbolsButton.isHidden = true
        morePanel.isHidden = true
        updateKeyboardHeight()
        publishPresence(visible: true, force: true)
        refreshSnapshot()
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
        keyboardIsVisible = false
        publishPresence(visible: false, force: true)
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
        view.backgroundColor = .clear
        keyboardHeight = view.heightAnchor.constraint(equalToConstant: 250)
        keyboardHeight?.priority = .defaultHigh
        keyboardHeight?.isActive = true

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.text = hasFullAccess
            ? "Start a recording in the app"
            : "Typing is ready. Enable Full Access for local dictation."

        transcriptLabel.font = .preferredFont(forTextStyle: .body)
        transcriptLabel.numberOfLines = 2
        transcriptLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
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

        let deleteButton = makeButton(title: "⌫", action: #selector(deleteBackward))
        deleteButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:))))
        let spaceButton = makeButton(title: "space", action: #selector(insertSpace))
        spaceButton.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveCursor(_:))))
        let returnButton = makeButton(title: "return", action: #selector(insertReturn))

        let more = makeButton(title: "More", action: #selector(showMore))
        let heading = UIStackView(arrangedSubviews: [modeButton, UIView(), more, endSessionButton])
        endSessionButton.accessibilityLabel = "End microphone session"
        endSessionButton.isHidden = true
        heading.axis = .horizontal
        heading.spacing = 8
        heading.alignment = .center

        let launch = UIHostingController(rootView: KeyboardAppLink { [weak self] in
            guard let self else { return }
            self.activationFailure = "iOS could not open Saywick. Use your Saywick Shortcut or open the app manually."
            self.statusLabel.text = self.activationFailure
        })
        addChild(launch)
        launch.view.backgroundColor = .clear
        launch.view.isHidden = true
        launch.didMove(toParent: self)
        launchController = launch
        let voiceControls = UIStackView(arrangedSubviews: [stopButton, launch.view!, insertButton])
        voiceControls.axis = .horizontal
        voiceControls.distribution = .fillEqually
        voiceControls.spacing = 8

        [restartButton, clearButton, undoButton].forEach { morePanel.addArrangedSubview($0) }
        morePanel.axis = .horizontal
        morePanel.distribution = .fillEqually
        morePanel.spacing = 6
        morePanel.isHidden = true

        let typingControls = UIStackView(
            arrangedSubviews: [nextKeyboardButton, symbolsButton, deleteButton, spaceButton, returnButton]
        )
        typingControls.axis = .horizontal
        typingControls.distribution = .fillProportionally
        typingControls.spacing = 8

        voicePanel.axis = .vertical
        voicePanel.spacing = 8
        [transcriptLabel, voiceControls].forEach { voicePanel.addArrangedSubview($0) }
        voicePanel.isHidden = false
        typingPanel.isHidden = true
        symbolsButton.isHidden = true
        typingPanel.axis = .vertical
        characterRows.axis = .vertical
        characterRows.spacing = 6
        typingPanel.addArrangedSubview(characterRows)
        rebuildKeys()

        let root = UIStackView(arrangedSubviews: [heading, statusLabel, voicePanel, typingPanel, morePanel, typingControls])
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let moreHeight = morePanel.heightAnchor.constraint(equalToConstant: 38)
        moreHeight.priority = .init(999)
        moreHeight.isActive = true
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            heading.heightAnchor.constraint(equalToConstant: 34),
            voiceControls.heightAnchor.constraint(equalToConstant: 44),

            typingControls.heightAnchor.constraint(equalToConstant: 42),
            spaceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
    }

    private func updateKeyboardHeight() {
        keyboardHeight?.constant = (typingPanel.isHidden ? 250 : 286) + (morePanel.isHidden ? 0 : 44)
    }

    @objc private func showMore() {
        morePanel.isHidden.toggle()
        updateKeyboardHeight()
    }

    @objc private func toggleTypingMode() {
        typingPanel.isHidden.toggle()
        voicePanel.isHidden = !typingPanel.isHidden
        modeButton.configuration?.title = typingPanel.isHidden ? "ABC" : "Voice"
        symbolsButton.isHidden = typingPanel.isHidden
        updateKeyboardHeight()
    }

    @objc private func toggleShift() {
        uppercase.toggle()
        rebuildKeys()
    }

    @objc private func toggleSymbols() {
        symbols.toggle()
        if typingPanel.isHidden { toggleTypingMode() }
        rebuildKeys()
    }

    private func rebuildKeys() {
        characterRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = symbols ? ["1234567890", "-/:;()$&@\"", ".,?!'[]{}#"] : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        for (index, characters) in rows.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 3
            if index == 2, !symbols { row.addArrangedSubview(shiftButton) }
            for character in characters {
                let value = uppercase && !symbols ? String(character).uppercased() : String(character)
                let key = makeButton(title: value, action: #selector(typeCharacter(_:)))
                key.accessibilityLabel = value
                key.accessibilityIdentifier = "typingKey_" + value
                key.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
                key.titleLabel?.font = .systemFont(ofSize: 20)
                row.addArrangedSubview(key)
            }
            characterRows.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
        shiftButton.configuration?.title = "⇧"
        shiftButton.configuration?.baseBackgroundColor = uppercase ? .systemBlue : nil
        shiftButton.configuration?.baseForegroundColor = uppercase ? .white : nil
        shiftButton.accessibilityLabel = uppercase ? "Shift on" : "Shift off"
        symbolsButton.configuration?.title = symbols ? "ABC" : "123"
    }

    @objc private func typeCharacter(_ sender: UIButton) {
        guard let value = sender.configuration?.title else { return }
        insertedText = nil
        textDocumentProxy.insertText(value)
        if uppercase && !symbols { uppercase = false; rebuildKeys() }
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = .bordered()
        button.configuration?.title = title
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func publishPresence(visible: Bool, force: Bool = false) {
        guard hasFullAccess else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPresenceWrite) >= 0.5 else { return }
        if visible { lastVisibleAt = now }
        guard let lastVisibleAt else { return }
        do {
            // An old controller disappearing must not hide its replacement.
            if !visible, let latest = try store?.readKeyboardPresence(),
               latest.keyboardID != keyboardID { return }
            try store?.write(presence: KeyboardPresence(keyboardID: keyboardID,
                isVisible: visible, lastVisibleAt: lastVisibleAt, updatedAt: now))
            lastPresenceWrite = now
        } catch { statusLabel.text = "Could not update keyboard presence: \(error.localizedDescription)" }
    }

    @objc private func refreshSnapshot() {
        if keyboardIsVisible { publishPresence(visible: true) }
        undoButton.isEnabled = canUndoInsertion
        do {
            if hasFullAccess, store == nil { store = try SharedContainerStore() }
            let snapshot = hasFullAccess ? try store?.readSnapshot() : nil
            currentSnapshot = snapshot
            var state = KeyboardRecordingState.resolve(snapshot, fullAccess: hasFullAccess)
            if let pending = pendingAction {
                let acknowledged = pending.command == .start
                    ? (state == .starting || state == .recording)
                    : (state == .finishing || state == .ready || state == .activationNeeded)
                if (acknowledged && (snapshot?.updatedAt ?? .distantPast) > pending.date) || Date().timeIntervalSince(pending.date) >= 5 { pendingAction = nil }
                else { state = pending.command == .start ? .starting : .finishing }
            }
            let needsLaunch = state == .activationNeeded && hasFullAccess
            launchController?.view.isHidden = !needsLaunch
            stopButton.isHidden = needsLaunch
            stopButton.configuration?.title = state.title
            stopButton.configuration?.image = UIImage(systemName: state == .recording || state == .meeting ? "stop.circle" : "mic.circle")
            stopButton.isEnabled = state != .starting && state != .finishing
            endSessionButton.isHidden = snapshot?.isKeyboardSessionActive() != true
            switch state {
            case .needsAccess: statusLabel.text = "Enable Full Access in keyboard Settings. ABC typing works without it."
            case .activationNeeded: statusLabel.text = activationFailure ?? "Microphone off. Open Saywick to start, then return here."
            case .ready: statusLabel.text = "Ready to dictate · microphone active"
            default: statusLabel.text = snapshot?.message
            }
            insertButton.isHidden = snapshot == nil || snapshot!.insertableText.isEmpty || hasInserted(snapshot!.sessionID)
            insertButton.isEnabled = snapshot?.phase == .ready
            restartButton.isEnabled = state == .recording
            clearButton.isEnabled = state != .meeting && state != .starting && state != .finishing && snapshot != nil
            guard let snapshot else { transcriptLabel.text = ""; return }
            let displayText = snapshot.phase == .ready ? snapshot.insertableText : snapshot.liveText
            transcriptLabel.text = hasInserted(snapshot.sessionID) ? "Inserted" : displayText
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
        let state = KeyboardRecordingState.resolve(currentSnapshot, fullAccess: hasFullAccess)
        guard pendingAction == nil else { return }
        guard let command = state.command else {
            statusLabel.text = state == .needsAccess
                ? "Settings → General → Keyboard → Keyboards → Saywick → Allow Full Access."
                : "Tap Open Saywick to activate the microphone."
            return
        }
        pendingAction = (command, Date())
        send(command, status: command == .start ? "Starting…" : "Finishing…")
        refreshSnapshot()
    }

    @objc private func endSession() {
        send(.endSession, status: "Ending microphone session…")
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
            if snapshot.phase != .listening && !snapshot.isKeyboardSessionActive() {
                try store?.clearSnapshot(ifSessionID: snapshot.sessionID)
                clearDisplayedSnapshot(status: "Cleared")
            }
            try store?.write(command: VoiceCommand(kind: .clear, sessionID: snapshot.sessionID))
            if snapshot.phase == .listening {
                statusLabel.text = "Clearing transcript…"
            }
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    private func send(_ command: VoiceCommandKind, status: String) {
        do {
            try store?.write(command: VoiceCommand(kind: command, sessionID: command == .endSession ? nil : currentSnapshot?.sessionID))
            statusLabel.text = status
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    private func consume(_ snapshot: SharedSessionSnapshot) {
        // Keep the ready session and its ID. Sending Clear here used to race
        // the next Start command because the app rotates its ID on Clear.
        if snapshot.isKeyboardSessionActive() {
            transcriptLabel.text = "Inserted"
            refreshSnapshot()
            return
        }
        do { try store?.clearSnapshot(ifSessionID: snapshot.sessionID) }
        catch { statusLabel.text = "Inserted; could not clear saved keyboard state" }
        refreshSnapshot()
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


/// Use SwiftUI's public URL action from a user tap, not a responder-chain selector.
private struct KeyboardAppLink: View {
    @Environment(\.openURL) private var openURL
    let rejected: () -> Void
    var body: some View {
        Button {
            openURL(URL(string: "saywick://start?source=keyboard")!) { accepted in
                if !accepted { rejected() }
            }
        } label: {
            Label("Open Saywick", systemImage: "arrow.up.forward.app")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("openSaywick")
    }
}
