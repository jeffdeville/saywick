import UIKit
import SwiftUI
import VoiceKeyboardCore

class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let transcriptLabel = LiveTranscriptView()
    private let stopButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let restartButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let keyboardID = UUID()
    private var keyboardIsVisible = false
    private var canInsertIntoHost = false
    private var lastVisibleAt: Date?
    private var lastPresenceWrite = Date.distantPast
    private var timer: Timer?
    private var pendingAction: PendingKeyboardCommand?
    private var lastAnnouncedIssue: String?
    private var lastRevision = -1
    private var currentSnapshot: SharedSessionSnapshot?
    var store: SharedContainerStore?
    private var insertedIDs: Set<UUID> = []
    private var insertedText: String?
    private var insertedContext: String?
    private var insertedDocument: UUID?
    private var deleteTimer: Timer?
    private var cursorOffset: CGFloat = 0
    private var uppercase = false
    private var symbols = false
    private var alternateSymbols = false
    private var sideConstraints: [NSLayoutConstraint] = []
    private let characterRows = UIStackView()
    private let voicePanel = UIStackView()
    private let rootStack = UIStackView()
    private let controlBar = UIStackView()
    private var primaryWidth: NSLayoutConstraint?
    private var showsTranscript = false
    private var isListeningLayout = false
    private let typingPanel = UIStackView()
    private let templateMenu = UIScrollView()
    private let templateRows = UIStackView()
    private var templateHeight: NSLayoutConstraint?
    private let morePanel = UIStackView()
    private var keyboardHeight: NSLayoutConstraint?
    private var launchController: UIHostingController<KeyboardAppLink>?
    private var correctionController: UIHostingController<KeyboardCorrectionLink>?
    private var activationFailure: String?

    private lazy var cleanupButton = makeButton(title: "Polish", action: #selector(toggleCleanup))
    private lazy var menuButton = makeButton(title: "More", action: #selector(showMore))
    private lazy var shiftButton = makeTypingKey(title: "⇧", action: #selector(toggleShift), utility: true)
    private lazy var symbolsButton = makeTypingKey(title: "123", action: #selector(toggleSymbols), utility: true)
    private lazy var endSessionButton = makeButton(title: "End", action: #selector(endSession))
    private lazy var cancelButton = makeButton(title: "Cancel", action: #selector(cancelDictation))
    private lazy var undoButton = makeButton(title: "Undo insertion", action: #selector(undoInsertion))

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()

        do {
            if hasFullAccess, store == nil { store = try SharedContainerStore() }
            refreshSnapshot()
        } catch {
            DiagnosticLog.error("keyboard.refresh", error)
            statusLabel.text = error.localizedDescription
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardIsVisible = true
        symbols = false; alternateSymbols = false; uppercase = false
        rebuildKeys()
        morePanel.isHidden = true
        templateMenu.isHidden = true
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canInsertIntoHost = true
        refreshSnapshot()
    }

    override func viewWillDisappear(_ animated: Bool) {
        canInsertIntoHost = false
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        keyboardIsVisible = false
        isListeningLayout = false
        publishPresence(visible: false, force: true)
        timer?.invalidate()
        timer = nil
        deleteTimer?.invalidate(); deleteTimer = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
    }

    private func updateTranscript(_ text: String) {
        guard transcriptLabel.text != text else { return }
        transcriptLabel.text = text
        transcriptLabel.scrollToEndOnLayout = true
        transcriptLabel.setNeedsLayout()
    }

    private lazy var nextKeyboardButton: UIButton = makeButton(
        title: "🌐",
        action: #selector(nextKeyboard)
    )

    private func configureView() {
        view.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.12, alpha: 1) : UIColor(red: 0.87, green: 0.88, blue: 0.90, alpha: 1) }
        keyboardHeight = view.heightAnchor.constraint(equalToConstant: 250)
        keyboardHeight?.priority = .defaultHigh
        keyboardHeight?.isActive = true

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.text = hasFullAccess
            ? "Start a recording in the app"
            : "Typing is ready. Enable Full Access for local dictation."

        transcriptLabel.font = .preferredFont(forTextStyle: .body)
        transcriptLabel.adjustsFontForContentSizeCategory = true
        transcriptLabel.isEditable = false
        transcriptLabel.isSelectable = true
        transcriptLabel.backgroundColor = .clear
        transcriptLabel.topEdgeEffect.isHidden = true
        transcriptLabel.bottomEdgeEffect.isHidden = true
        transcriptLabel.textContainerInset = .zero
        transcriptLabel.textContainer.lineFragmentPadding = 0
        transcriptLabel.accessibilityIdentifier = "keyboardTranscript"
        transcriptLabel.accessibilityLabel = "Live transcript"
        transcriptLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        transcriptLabel.text = "No transcript yet"

        stopButton.configuration = .filled()
        stopButton.configuration?.title = nil
        stopButton.configuration?.image = UIImage(systemName: "mic.fill")
        stopButton.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 28, weight: .semibold)
        stopButton.accessibilityIdentifier = "dictationAction"
        stopButton.configuration?.cornerStyle = .capsule
        stopButton.configuration?.imagePadding = 6
        stopButton.titleLabel?.numberOfLines = 1
        stopButton.titleLabel?.adjustsFontSizeToFitWidth = true
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

        for (button, symbol, label) in [(menuButton, "line.3.horizontal", "More"),
                                         (undoButton, "arrow.uturn.backward", "Undo insertion")] {
            button.configuration = .plain()
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 23)
            button.configuration?.baseForegroundColor = .label
            button.accessibilityLabel = label
            let width = button.widthAnchor.constraint(equalToConstant: 40)
            width.priority = .init(999); width.isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        endSessionButton.accessibilityLabel = "End microphone session"
        nextKeyboardButton.configuration = .plain()
        nextKeyboardButton.configuration?.image = UIImage(systemName: "globe")
        nextKeyboardButton.configuration?.baseForegroundColor = .label
        nextKeyboardButton.accessibilityLabel = "Next keyboard"

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
        [menuButton, undoButton, cancelButton, UIView(), cleanupButton, launch.view!, stopButton].forEach { controlBar.addArrangedSubview($0) }
        controlBar.axis = .horizontal
        controlBar.distribution = .fill
        controlBar.alignment = .center
        controlBar.spacing = 6
        cancelButton.configuration?.title = nil
        cancelButton.configuration?.image = UIImage(systemName: "xmark")
        cancelButton.accessibilityLabel = "Cancel dictation"
        cleanupButton.setContentHuggingPriority(.required, for: .horizontal)
        primaryWidth = stopButton.widthAnchor.constraint(equalToConstant: 56)
        let controlSizes = [
            cancelButton.widthAnchor.constraint(equalToConstant: 44),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
            cleanupButton.heightAnchor.constraint(equalToConstant: 44),
            primaryWidth!,
            stopButton.heightAnchor.constraint(equalToConstant: 56),
            launch.view.heightAnchor.constraint(equalToConstant: 56),
            launch.view.widthAnchor.constraint(equalToConstant: 56),
            insertButton.heightAnchor.constraint(equalToConstant: 44),
        ]
        for constraint in controlSizes {
            constraint.priority = .init(999)
            constraint.isActive = true
        }

        [endSessionButton, restartButton, clearButton].forEach { morePanel.addArrangedSubview($0) }
        morePanel.axis = .horizontal
        morePanel.distribution = .fillEqually
        morePanel.spacing = 6
        morePanel.isHidden = true

        voicePanel.axis = .vertical
        voicePanel.addArrangedSubview(transcriptLabel)
        let correction = UIHostingController(rootView: KeyboardCorrectionLink(context: nil, prepare: { _ in false }, rejected: {}))
        addChild(correction)
        correction.view.backgroundColor = .clear
        correction.view.accessibilityIdentifier = "correctionRow"
        correction.view.isHidden = true
        correction.didMove(toParent: self)
        correctionController = correction
        let correctionHeight = correction.view.heightAnchor.constraint(equalToConstant: 30)
        correctionHeight.priority = .init(999); correctionHeight.isActive = true
        voicePanel.isHidden = true
        typingPanel.isHidden = false
        typingPanel.axis = .vertical
        characterRows.axis = .vertical
        characterRows.spacing = 10
        typingPanel.spacing = 10
        typingPanel.addArrangedSubview(characterRows)
        let space = makeTypingKey(title: "space", action: #selector(insertSpace))
        space.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveCursor(_:))))
        let enter = makeTypingKey(title: "return", action: #selector(insertReturn), utility: true)
        enter.configuration?.title = nil
        enter.configuration?.image = UIImage(systemName: "return")
        enter.accessibilityLabel = "return"
        let bottom = UIStackView(arrangedSubviews: [symbolsButton, nextKeyboardButton, space, enter])
        bottom.spacing = 6
        bottom.axis = .horizontal
        typingPanel.addArrangedSubview(bottom)
        bottom.heightAnchor.constraint(equalToConstant: 42).isActive = true
        symbolsButton.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.17).isActive = true
        enter.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.22).isActive = true
        let globeWidth = nextKeyboardButton.widthAnchor.constraint(equalToConstant: 36)
        globeWidth.priority = .init(999); globeWidth.isActive = true
        rebuildKeys()

        templateMenu.isHidden = true
        templateRows.axis = .vertical
        templateRows.translatesAutoresizingMaskIntoConstraints = false
        templateMenu.addSubview(templateRows)
        let content = templateMenu.contentLayoutGuide
        NSLayoutConstraint.activate([
            templateRows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            templateRows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            templateRows.topAnchor.constraint(equalTo: content.topAnchor),
            templateRows.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            templateRows.widthAnchor.constraint(equalTo: templateMenu.frameLayoutGuide.widthAnchor)
        ])
        templateHeight = templateMenu.heightAnchor.constraint(equalToConstant: 88)
        templateHeight?.priority = .init(999)
        templateHeight?.isActive = true
        [controlBar, statusLabel, voicePanel, templateMenu, insertButton, typingPanel, correction.view!, morePanel].forEach { rootStack.addArrangedSubview($0) }
        rootStack.axis = .vertical
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        let moreHeight = morePanel.heightAnchor.constraint(equalToConstant: 38)
        moreHeight.priority = .init(999); moreHeight.isActive = true
        sideConstraints = [rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                           rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6)]
        NSLayoutConstraint.activate(sideConstraints)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            controlBar.heightAnchor.constraint(equalToConstant: 56),
            space.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
    }

    private func updatePresentation(state: KeyboardRecordingState, snapshot: SharedSessionSnapshot?, consumed: Bool) {
        let staleRecording = state == .activationNeeded
            && snapshot.map { [.preparing, .listening, .finalizing].contains($0.phase) } == true
        let active = [.starting, .recording, .finishing, .meeting].contains(state) || staleRecording
        let result = !consumed && !(snapshot?.insertableText.isEmpty ?? true)
            && (snapshot?.phase == .ready || snapshot?.phase == .failed)
        let transcript = active || result
        isListeningLayout = state == .recording || state == .meeting
        typingPanel.isHidden = transcript
        voicePanel.isHidden = !transcript
        menuButton.isHidden = active
        undoButton.isHidden = active
        cancelButton.isHidden = !isListeningLayout
        statusLabel.isHidden = snapshot?.templateFallback == nil && !staleRecording && !result && activationFailure == nil && pendingAction == nil
            && snapshot?.phase != .failed && state != .starting && state != .finishing
        if active { morePanel.isHidden = true }
        // Move the same controls, keeping their targets/settings synchronized.
        if showsTranscript != transcript {
            controlBar.removeFromSuperview()
            let position = transcript ? (rootStack.arrangedSubviews.firstIndex(of: voicePanel)! + 1) : 0
            rootStack.insertArrangedSubview(controlBar, at: position)
            showsTranscript = transcript
        }
        primaryWidth?.constant = transcript ? 104 : 56
        correctionController?.view.isHidden = transcript || insertedText == nil
        updateKeyboardHeight()
    }

    private func updateKeyboardHeight() {
        let extras = (morePanel.isHidden ? 0 : 46) + (statusLabel.isHidden ? 0 : 38)
            + (correctionController?.view.isHidden == false ? 38 : 0)
        keyboardHeight?.constant = CGFloat(showsTranscript ? 250 : 274) + CGFloat(extras) + (templateMenu.isHidden ? 0 : (templateHeight?.constant ?? 0) + 8)
        sideConstraints.first?.constant = showsTranscript ? 12 : 6
        sideConstraints.last?.constant = showsTranscript ? -12 : -6
    }

    @objc private func showMore() {
        morePanel.isHidden.toggle()
        updateKeyboardHeight()
    }

    @objc private func toggleShift() {
        if symbols { alternateSymbols.toggle() } else { uppercase.toggle() }
        rebuildKeys()
    }

    @objc private func toggleSymbols() {
        symbols.toggle()
        alternateSymbols = false
        rebuildKeys()
    }

    private func makeTypingKey(title: String, action: Selector, utility: Bool = false) -> UIButton {
        let key = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = .zero
        config.background.cornerRadius = 8
        config.background.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: utility ? 0.22 : 0.36, alpha: 1)
                : (utility ? UIColor(red: 0.67, green: 0.69, blue: 0.72, alpha: 1) : .white)
        }
        config.baseForegroundColor = .label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: title.count == 1 ? 23 : 16)
            return attributes
        }
        key.configuration = config
        key.layer.shadowColor = UIColor.black.cgColor
        key.layer.shadowOpacity = 0.08
        key.layer.shadowOffset = CGSize(width: 0, height: 1)
        key.layer.shadowRadius = 0
        key.addTarget(self, action: action, for: .touchUpInside)
        return key
    }

    private func rebuildKeys() {
        characterRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = symbols
            ? (alternateSymbols ? ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"] : ["1234567890", "-/:;()$&@\"", ".,?!'"])
            : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        var firstKey: UIButton?
        for (index, characters) in rows.enumerated() {
            let container = UIView()
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fill
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            characterRows.addArrangedSubview(container)
            container.heightAnchor.constraint(equalToConstant: 42).isActive = true
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                row.topAnchor.constraint(equalTo: container.topAnchor),
                row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                row.widthAnchor.constraint(equalTo: container.widthAnchor,
                    multiplier: index == 1 && !symbols ? 0.9 : 1,
                    constant: index == 1 && !symbols ? -0.6 : 0)
            ])
            if index == 2 { row.addArrangedSubview(shiftButton) }
            var rowFirst: UIButton?
            for character in characters {
                let value = uppercase && !symbols ? String(character).uppercased() : String(character)
                let key = makeTypingKey(title: value, action: #selector(typeCharacter(_:)))
                key.accessibilityLabel = value
                key.accessibilityIdentifier = "typingKey_" + value
                row.addArrangedSubview(key)
                if index < 2 || !symbols {
                    if let firstKey { key.widthAnchor.constraint(equalTo: firstKey.widthAnchor).isActive = true }
                } else if let rowFirst { key.widthAnchor.constraint(equalTo: rowFirst.widthAnchor).isActive = true }
                if firstKey == nil { firstKey = key }
                if rowFirst == nil { rowFirst = key }
            }
            if index == 2 {
                let delete = makeTypingKey(title: "⌫", action: #selector(deleteBackward), utility: true)
                delete.accessibilityLabel = "Delete"
                delete.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:))))
                row.addArrangedSubview(delete)
                delete.widthAnchor.constraint(equalTo: shiftButton.widthAnchor).isActive = true
                if symbols { shiftButton.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.12).isActive = true }
            }
        }
        shiftButton.configuration?.title = symbols ? (alternateSymbols ? "123" : "#+=") : "⇧"
        let shiftActive = uppercase && !symbols
        shiftButton.configuration?.background.backgroundColor = UIColor { traits in
            shiftActive ? .white : (traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.22, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.72, alpha: 1))
        }
        shiftButton.accessibilityLabel = symbols ? "More symbols" : (uppercase ? "Shift on" : "Shift off")
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
        } catch { DiagnosticLog.error("keyboard.operation", error); statusLabel.text = "Could not update keyboard presence: \(error.localizedDescription)" }
    }

    @objc private func refreshSnapshot() {
        if keyboardIsVisible { publishPresence(visible: true) }
        undoButton.isEnabled = canUndoInsertion
        do {
            if hasFullAccess, store == nil { store = try SharedContainerStore() }
            let snapshot = hasFullAccess ? try store?.readSnapshot() : nil
            let state = KeyboardRecordingState.resolve(snapshot, fullAccess: hasFullAccess)
            if state != .recording || currentSnapshot?.sessionID != snapshot?.sessionID
                || currentSnapshot?.templateChoices != snapshot?.templateChoices
                || currentSnapshot?.selectedTemplate != snapshot?.selectedTemplate {
                templateMenu.isHidden = true
            }
            if pendingAction == nil, state == .recording, let snapshot,
               let outstanding = try store?.readCommand(), outstanding.kind == .selectTemplate,
               outstanding.sessionID == snapshot.sessionID, snapshot.acknowledgment?.id != outstanding.id,
               abs(outstanding.issuedAt.timeIntervalSinceNow) < 10 {
                pendingAction = PendingKeyboardCommand(command: outstanding, sentAt: outstanding.issuedAt)
            }
            currentSnapshot = snapshot
            let receipt = try snapshot.flatMap { try store?.readReceipt($0.sessionID) }
            let consumed = snapshot.map { hasInserted($0.sessionID) } == true || receipt != nil
            let hasRecovery = snapshot?.phase == .failed && snapshot?.dictation?.pending == nil
                && !(snapshot?.insertableText.isEmpty ?? true) && !consumed
            let enabled = try store?.cleanupEnabled() ?? true
            let configured = snapshot?.cleanupConfigured != false
            let hasMenu = state == .recording && !(snapshot?.templateChoices?.isEmpty ?? true)
            let selected = hasMenu ? snapshot?.selectedTemplate : nil
            let polished = selected != nil || (enabled && configured)
            var polish = UIButton.Configuration.plain()
            polish.baseForegroundColor = polished ? .systemBlue : .secondaryLabel
            polish.background.backgroundColor = polished ? UIColor.systemBlue.withAlphaComponent(0.14) : .clear
            polish.background.cornerRadius = 22
            polish.background.strokeColor = polished ? .clear : .separator
            polish.background.strokeWidth = polished ? 0 : 1
            polish.title = selected?.name ?? (hasMenu && !enabled ? "Off" : "Polish")
            polish.titleLineBreakMode = .byTruncatingTail
            polish.image = UIImage(systemName: hasMenu ? "chevron.down" : "sparkles")
            polish.imagePadding = 4
            cleanupButton.configuration = polish
            cleanupButton.accessibilityLabel = "Polish"
            cleanupButton.accessibilityValue = configured ? (enabled ? "On" : "Off") : "Unavailable"
            cleanupButton.accessibilityHint = configured ? "Toggles text cleanup for this dictation" : "Choose a cleanup method in Saywick"
            cleanupButton.accessibilityTraits = polished ? [.button, .selected] : [.button]
            cleanupButton.isEnabled = hasFullAccess && store != nil && configured
            if hasMenu {
                cleanupButton.accessibilityLabel = "Cleanup choices"
                cleanupButton.accessibilityValue = selected?.name ?? (enabled ? "Polish" : "Off")
                cleanupButton.accessibilityHint = "Choose a template for this recording"
            }
            if let pending = pendingAction, snapshot?.acknowledgment?.id == pending.command.id {
                activationFailure = snapshot?.acknowledgment?.rejection
                pendingAction = nil
            }
            cleanupButton.isEnabled = cleanupButton.isEnabled && pendingAction == nil
            let needsLaunch = state == .activationNeeded && hasFullAccess
            launchController?.view.isHidden = !needsLaunch
            launchController?.view.isUserInteractionEnabled = !hasRecovery
            launchController?.view.alpha = hasRecovery ? 0.45 : 1
            stopButton.isHidden = needsLaunch
            let recording = state == .recording || state == .meeting
            stopButton.configuration?.title = nil
            stopButton.configuration?.image = UIImage(systemName: recording ? "stop.fill" : "mic.fill")
            stopButton.configuration?.showsActivityIndicator = state == .starting || state == .finishing
            stopButton.configuration?.baseBackgroundColor = recording ? .systemRed : .label
            stopButton.configuration?.baseForegroundColor = recording ? .white : .systemBackground
            stopButton.accessibilityLabel = recording ? "Stop and insert" : (state == .ready ? "Start dictation" : state.title)
            stopButton.accessibilityValue = recording ? "Listening" : nil
            stopButton.isEnabled = state != .starting && state != .finishing && (pendingAction == nil || pendingAction!.timedOut(at: Date()))
            endSessionButton.isHidden = snapshot?.isKeyboardSessionActive() != true
            switch state {
            case .needsAccess: statusLabel.text = "Enable Full Access in keyboard Settings. ABC typing works without it."
            case .activationNeeded:
                statusLabel.text = activationFailure ?? (hasRecovery
                    ? "Interrupted · insert unfinished text before starting again"
                    : snapshot?.dictation?.issue ?? (snapshot?.phase == .failed ? snapshot?.message : nil))
                    ?? "Microphone off. Open Saywick to start, then return here."
            case .ready: statusLabel.text = "Ready to dictate · microphone active"
            default: statusLabel.text = snapshot?.message
            }
            if let rejection = activationFailure { statusLabel.text = rejection }
            if let notice = snapshot?.templateFallback { statusLabel.text = notice }
            if let pending = pendingAction {
                statusLabel.text = pending.timedOut(at: Date()) ? "Recorder did not acknowledge. Tap again to retry." : "Waiting for recorder…"
            }
            if let issue = snapshot?.dictation?.issue, issue != lastAnnouncedIssue {
                lastAnnouncedIssue = issue
                UIAccessibility.post(notification: .announcement, argument: issue)
            }
            cancelButton.isEnabled = state == .recording && pendingAction == nil
            insertButton.isHidden = snapshot == nil || snapshot!.insertableText.isEmpty || hasInserted(snapshot!.sessionID)
            insertButton.isHidden = insertButton.isHidden || state == .recording || state == .meeting || state == .starting || state == .finishing
            let recoverable = snapshot?.phase == .failed && snapshot?.dictation?.pending == nil
            insertButton.configuration?.title = recoverable ? "Insert recovered" : "Insert Latest"
            insertButton.isEnabled = snapshot?.phase == .ready || recoverable
            restartButton.isEnabled = state == .recording
            clearButton.isEnabled = state != .recording && state != .meeting && state != .starting && state != .finishing && snapshot != nil
            if consumed { insertButton.isHidden = true }
            updatePresentation(state: state, snapshot: snapshot, consumed: consumed)
            guard let snapshot else { updateTranscript(""); return }
            let displayText = snapshot.phase == .ready || (snapshot.phase == .failed && snapshot.dictation?.pending == nil) ? snapshot.insertableText : snapshot.liveText
            updateTranscript(consumed ? "Inserted or dismissed" : displayText)
            if snapshot.phase == .ready,
               snapshot.shouldAutoInsert,
               !snapshot.insertableText.isEmpty,
               !consumed,
               insert(snapshot.insertableText) {
                rememberInserted(snapshot.sessionID)
                consume(snapshot)
            }
        } catch {
            DiagnosticLog.error("keyboard.refresh", error)
            statusLabel.text = error.localizedDescription
            statusLabel.isHidden = false; updateKeyboardHeight()
        }
    }

    @objc private func toggleCleanup() {
        do {
            guard let store else { return }
            if KeyboardRecordingState.resolve(currentSnapshot, fullAccess: hasFullAccess) == .recording,
               let snapshot = currentSnapshot, let choices = snapshot.templateChoices, !choices.isEmpty {
                if templateMenu.isHidden { showTemplateMenu(snapshot, choices: choices, enabled: try store.cleanupEnabled()) }
                else { templateMenu.isHidden = true; updateKeyboardHeight() }
                return
            }
            try store.setCleanupEnabled(!store.cleanupEnabled())
            refreshSnapshot()
        } catch { statusLabel.text = "Could not change cleanup: \(error.localizedDescription)" }
    }

    private func showTemplateMenu(_ snapshot: SharedSessionSnapshot, choices: [CleanupTemplateChoice], enabled: Bool) {
        for row in templateRows.arrangedSubviews { row.removeFromSuperview() }
        func addRow(_ title: String, selected: Bool = false, action: @escaping () -> Void) {
            let button = UIButton(type: .system)
            button.configuration = .plain()
            button.configuration?.title = title
            button.configuration?.image = selected ? UIImage(systemName: "checkmark") : nil
            button.configuration?.imagePadding = 6
            button.contentHorizontalAlignment = .leading
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            if selected { button.accessibilityTraits.insert(.selected) }
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                templateMenu.isHidden = true
                guard currentSnapshot?.sessionID == snapshot.sessionID else { refreshSnapshot(); return }
                action()
                refreshSnapshot()
            }, for: .touchUpInside)
            templateRows.addArrangedSubview(button)
        }
        if snapshot.selectedTemplate != nil {
            addRow(enabled ? "Use regular Polish" : "Use Off") { [weak self] in
                self?.send(.selectTemplate, status: "Restoring usual cleanup…")
            }
        } else {
            addRow(enabled ? "Turn Polish off" : "Turn Polish on") { [weak self] in
                do { try self?.store?.setCleanupEnabled(!enabled) }
                catch { self?.activationFailure = "Could not change Polish." }
            }
        }
        for choice in choices {
            addRow(choice.name, selected: choice.id == snapshot.selectedTemplate?.id) { [weak self] in
                self?.send(.selectTemplate, status: "Selecting template…", templateID: choice.id)
            }
        }
        templateHeight?.constant = CGFloat(min(3, templateRows.arrangedSubviews.count)) * 44
        templateMenu.setContentOffset(.zero, animated: false)
        templateMenu.isHidden = false
        updateKeyboardHeight()
    }

    @objc private func stopAndInsert() {
        let state = KeyboardRecordingState.resolve(currentSnapshot, fullAccess: hasFullAccess)
        if let pending = pendingAction {
            guard pending.timedOut(at: Date()) else { return }
            do { try store?.write(command: pending.command) }
            catch { DiagnosticLog.error("keyboard.operation", error); statusLabel.text = error.localizedDescription }
            return
        }
        guard let command = state.command else {
            activationFailure = state == .needsAccess
                ? "Settings → General → Keyboard → Keyboards → Saywick → Allow Full Access."
                : "Tap the microphone to open Saywick."
            refreshSnapshot()
            return
        }
        send(command, status: command == .start ? "Starting…" : "Finishing…")
        refreshSnapshot()
    }

    @objc private func endSession() {
        send(.endSession, status: "Ending microphone session…")
    }

    @objc private func insertLatest() {
        guard let snapshot = currentSnapshot,
              !snapshot.insertableText.isEmpty,
              insert(snapshot.insertableText) else { return }
        rememberInserted(snapshot.sessionID)
        consume(snapshot)
    }

    @objc private func restartTranscript() {
        send(.restart, status: "Restarting transcript…")
    }

    @objc private func cancelDictation() { send(.cancel, status: "Cancelling…") }

    @objc private func clearTranscript() {
        guard let snapshot = currentSnapshot else { return }
        guard snapshot.phase != .listening, snapshot.phase != .preparing, snapshot.phase != .finalizing else { return }
        do {
            try store?.write(receipt: ResultReceipt(resultID: snapshot.sessionID, disposition: .dismissed))
            refreshSnapshot()
        } catch { DiagnosticLog.error("keyboard.operation", error); statusLabel.text = error.localizedDescription }
    }

    private func send(_ command: VoiceCommandKind, status: String, templateID: UUID? = nil) {
        guard pendingAction == nil else { return }
        var request = VoiceCommand(kind: command, sessionID: command == .endSession ? nil : currentSnapshot?.sessionID)
        request.templateID = templateID
        do {
            try store?.write(command: request)
            pendingAction = PendingKeyboardCommand(command: request)
            statusLabel.text = status
        } catch { DiagnosticLog.error("keyboard.operation", error); statusLabel.text = error.localizedDescription }
    }

    private func consume(_ snapshot: SharedSessionSnapshot) {
        do { try store?.write(receipt: ResultReceipt(resultID: snapshot.sessionID, disposition: .inserted)) }
        catch { DiagnosticLog.error("keyboard.operation", error); statusLabel.text = "Inserted; could not save insertion receipt" }
        refreshSnapshot()
    }

    @discardableResult
    private func insert(_ text: String) -> Bool {
        // Loading/transitioning keyboards may have a proxy that cannot accept text yet.
        // Leave the result unconsumed until this keyboard is attached and has appeared.
        guard canInsertIntoHost, viewIfLoaded?.window != nil else { return false }
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
        insertedDocument = currentDocumentIdentifier()
        undoButton.isEnabled = canUndoInsertion
        let context = VocabularyCorrectionContext(transcript: text)
        correctionController?.rootView = KeyboardCorrectionLink(context: context, prepare: { [weak self] context in
            guard let self else { return false }
            do {
                guard let store = self.store else { throw SharedContainerError.missingAppGroupIdentifier }
                try store.write(correctionContext: context)
                return true
            } catch {
                self.statusLabel.text = "Could not prepare correction. Try again or open Saywick History."
                return false
            }
        }, rejected: { [weak self] in
            try? self?.store?.removeCorrectionContext()
            self?.statusLabel.text = "iOS could not open Saywick. Open the app and add a correction in History."
        })
        correctionController?.view.isHidden = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
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
        insertedIDs.contains(id) || insertedDefaults?.string(forKey: "lastInsertedSession") == id.uuidString
    }

    private func rememberInserted(_ id: UUID) {
        insertedIDs.insert(id)
    }

    private var insertedDefaults: UserDefaults? {
        guard let identifier = Bundle.main.object(
            forInfoDictionaryKey: "AppGroupIdentifier"
        ) as? String else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    private func currentDocumentIdentifier() -> UUID? {
        // Some host proxies return nil despite UIKit's nonnull declaration. Reading
        // the Swift UUID property traps before an optional cast can handle it.
        // Fetch the public Objective-C getter as an object, then bridge if present.
        let selector = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let proxy = textDocumentProxy as? NSObject,
              proxy.responds(to: selector),
              let identifier = proxy.perform(selector)?.takeUnretainedValue() as? NSUUID else { return nil }
        return identifier as UUID
    }

    private var canUndoInsertion: Bool {
        guard let insertedDocument, let currentDocument = currentDocumentIdentifier(),
              let insertedText, !insertedText.isEmpty, let context = textDocumentProxy.documentContextBeforeInput else { return false }
        return insertedDocument == currentDocument && context == insertedContext && context.hasSuffix(insertedText)
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
            Image(systemName: "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .background(Color.primary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Saywick to start dictation")
        .accessibilityIdentifier("openSaywick")
    }
}

/// Scroll after the text view itself has its final bounds and text layout.
private final class LiveTranscriptView: UITextView {
    var scrollToEndOnLayout = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard scrollToEndOnLayout, bounds.width > 0, bounds.height > 0 else { return }
        scrollToEndOnLayout = false
        let contentHeight = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        setContentOffset(CGPoint(x: 0, y: max(0, contentHeight - bounds.height)), animated: false)
    }
}

private struct KeyboardCorrectionLink: View {
    @Environment(\.openURL) private var openURL
    let context: VocabularyCorrectionContext?
    let prepare: (VocabularyCorrectionContext) -> Bool
    let rejected: () -> Void
    var body: some View {
        if let context {
            Button {
                guard prepare(context) else { return }
                openURL(URL(string: "saywick://fix-word?id=" + context.id.uuidString)!) { accepted in
                    if !accepted { rejected() }
                }
            } label: {
                Label("Fix a word", systemImage: "character.cursor.ibeam")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityIdentifier("fixAWord")
        }
    }
}
