import AppKit
import SwiftUI

/// Clicks on a panel that never becomes key must still reach the buttons on the first try.
/// Also the drop target for files dragged onto the notch.
private final class NotchHostingView: NSHostingView<NotchRootView> {
    var onDrop: ((URL) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.fileURL(sender.draggingPasteboard) else { return false }
        return onDrop?(url) ?? false
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURL(sender.draggingPasteboard).map(FileDrop.looksSupported) == true ? .copy : []
    }

    static func fileURL(_ pb: NSPasteboard) -> URL? {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
}

private final class NotchPanel: NSPanel {
    /// Only while the chat is open: a non-activating panel can then take typing without
    /// pulling focus away from the app you're in.
    var allowsKey = false
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { allowsKey }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeMain: Bool { false }
    // Borderless windows may sit over the menu bar; don't let AppKit push us below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// "Notch" mode: a black island glued to the camera cutout that grows and drops down.
/// The panel is a fixed transparent canvas; SwiftUI animates the shape inside it and
/// clicks outside the shape fall through to whatever is underneath.
final class NotchController {
    let model: NotchModel
    private let prefs: Prefs
    private let brain: Brain
    private let buddy: BuddyView
    private var panel: NotchPanel!
    private var timer: Timer?
    private var ticks = 0
    private var outsideSince: Date?
    private var hovering = false
    private var lastMood: Mood?
    private var doneUntil: Date?
    private var approval: ApprovalTicket?
    private var approvalTimer: Timer?
    private(set) var chatOpen = false
    private var chatPhase = ChatPhase.input
    private var chatHistory: [(question: String, answer: String)] = []
    private let runner = ClaudeRunner()
    private var clickMonitor: Any?
    /// The file this chat is about, kept for follow-ups and deleted when the chat closes.
    private var chatFile: DroppedFile?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private lazy var dragBaseline = dragPasteboard.changeCount
    /// A file is being dragged somewhere on screen (left button down, files on the drag pasteboard).
    private var dragFile: URL?
    /// The latest screenshot of this chat, kept for follow-ups and deleted when the chat closes.
    private var screenshot: URL?
    private var clipWatch: Timer?
    private var hiddenForFullscreen = false
    /// Set while the demo runs: the state it is showing right now.
    private var demoState: NotchState?
    private var demoTimers: [Timer] = []
    private var observers: [NSObjectProtocol] = []
    private(set) var isShown = false

    init(prefs: Prefs, brain: Brain, buddy: BuddyView) {
        self.prefs = prefs
        self.brain = brain
        self.buddy = buddy
        model = NotchModel(buddy: buddy)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let host = NotchHostingView(rootView: NotchRootView(model: model))
        host.registerForDraggedTypes([.fileURL])
        host.onDrop = { [weak self] in self?.dropped($0) ?? false }
        panel.contentView = host
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onCancel = { [weak self] in self?.closeChat() }
        model.onApprovalAnswer = { [weak self] in self?.answerApproval($0) }
        model.onChatSubmit = { [weak self] in self?.ask($0) }
        model.onChatClose = { [weak self] in self?.closeChat() }
        model.onOpenChat = { [weak self] in self?.openChat() }
        model.onDescribeScreen = { [weak self] in self?.describeScreen() }
        applyPrefs()
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        layout()
        hiddenForFullscreen = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        checkFullscreen()

        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.checkFullscreen()
            },
            ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                // The space switch animation is still running; look once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.checkFullscreen() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in self?.layout() },
        ]
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        timer?.invalidate()
        timer = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
        stopDemo()
        dismissApproval()
        closeChat()
        panel.orderOut(nil)
        hovering = false
        doneUntil = nil
        model.state = .compact
        model.outline = .none
        model.flash = nil
    }

    func applyPrefs() {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !prefs.hideInFullscreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior
        if isShown { checkFullscreen(); updateOutline() }
    }

    func set(_ state: NotchState) {
        guard state != model.state else { return }
        withAnimation(NotchStyle.spring) { model.state = state }
    }

    // MARK: Approval

    /// Drops the card down for a permission request. Returns false (and the caller answers
    /// "terminal") when it can't be shown right now.
    func presentApproval(_ ticket: ApprovalTicket) -> Bool {
        guard isShown, !hiddenForFullscreen, approval == nil else { return false }
        stopDemo()
        approval = ticket
        model.approvalTitle = ApprovalChannel.visible(L10n.approvalTitle(tool: ticket.request.tool))
        let detail = ApprovalChannel.visible(ticket.request.detail)
        let lines = CommandLabel.lineCount(detail)
        model.approvalDetail = detail
        model.approvalFits = lines <= CommandLabel.maxLines
        model.approvalLines = min(lines, CommandLabel.maxLines)
        model.approvalSince = Date()
        // Answered in the terminal / editor, or Claude Code gave up on the hook.
        ticket.onHangup = { [weak self] in self?.closeApproval() }
        brain.handle(["event": "Notification", "kind": "permission_prompt"])

        // Not answered in time: fold away; the outline keeps breathing and the terminal decides.
        let t = Timer(timeInterval: ApprovalChannel.cardSeconds, repeats: false) { [weak self] _ in
            self?.answerApproval(.terminal)
        }
        RunLoop.main.add(t, forMode: .common)
        approvalTimer = t
        set(.approval)
        return true
    }

    /// Hands any open request back to the terminal (e.g. the turn ended meanwhile).
    func dismissApproval() { answerApproval(.terminal) }

    private func answerApproval(_ decision: ApprovalDecision) {
        guard let ticket = approval else { return }
        // A card that just dropped under a moving pointer shouldn't catch a stray click.
        if decision != .terminal && Date().timeIntervalSince(model.approvalSince) < 0.7 { return }
        // Never allow what didn't fit on the card.
        if decision == .allow && !model.approvalFits { return }
        ticket.answer(decision)
        closeApproval()
        if decision != .terminal { brain.permissionAnswered() }
    }

    private func closeApproval() {
        approval = nil
        approvalTimer?.invalidate()
        approvalTimer = nil
    }

    // MARK: Chat

    func toggleChat() { chatOpen ? closeChat() : openChat() }

    /// Drops the chat card and puts the cursor in its field. Each opening is a fresh conversation.
    func openChat() {
        guard isShown, !hiddenForFullscreen, !chatOpen else { return }
        stopDemo()
        chatOpen = true
        chatHistory = []
        chatPhase = .input
        model.chatQuestion = ""
        model.chatAnswer = ""
        model.chatError = false
        model.chatAnswerHeight = 0
        model.chatNote = ""
        set(chatState)
        panel.allowsKey = true
        panel.makeKey()
        // A click anywhere else closes it, like a popover. Mouse monitors need no permission.
        // Not while the user drags out a ⌘⌃⇧4 selection for us.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.model.chatAwaitingClip != true { self?.closeChat() }
        }
    }

    func closeChat() {
        guard chatOpen else { return }
        chatOpen = false
        runner.cancel()
        FileDrop.discard(chatFile)
        chatFile = nil
        stopClipWatch()
        setScreenshot(nil)
        model.chatAttachScreen = false
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        model.chatField = nil
        panel.allowsKey = false
        if panel.isKeyWindow {
            // Give the keyboard back to the app you were in. By now the island is folded into the
            // cutout, so re-ordering the panel is invisible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, !self.chatOpen, self.isShown else { return }
                self.panel.orderOut(nil)
                self.panel.orderFrontRegardless()
            }
        }
    }

    private var chatState: NotchState {
        switch chatPhase {
        case .input: return .chatInput
        case .thinking: return .chatThinking
        case .answer: return .chatAnswer
        }
    }

    /// "What's on my screen?" from the hotkey or the hover button: opens the chat if needed.
    func describeScreen() {
        if !chatOpen { openChat() }
        guard chatOpen else { return }
        ask(L10n.ui(.screenQuestion), withScreen: true)
    }

    /// `prompt` replaces the usual one (the file summary request). A screenshot goes along when asked
    /// for: the hotkey, the button by the field, or a message that mentions the screen.
    private func ask(_ question: String, prompt custom: String? = nil, withScreen: Bool = false) {
        guard chatOpen, chatPhase != .thinking else { return }
        let wantsScreen = custom == nil && (withScreen || model.chatAttachScreen || ScreenGrab.mentionsScreen(question))
        model.chatAttachScreen = false
        if custom == nil { model.chatNote = "" }
        model.chatQuestion = question
        model.chatAnswer = ""
        model.chatError = false
        model.chatLookingAtScreen = wantsScreen
        chatPhase = .thinking
        guard wantsScreen else { run(question, prompt: custom); return }
        grabScreen { [weak self] url in
            guard let self, self.chatOpen else { return }
            self.setScreenshot(url)
            self.run(question, prompt: nil)
        }
    }

    private func setScreenshot(_ url: URL?) {
        if let old = screenshot, old != url { try? FileManager.default.removeItem(at: old) }
        screenshot = url
    }

    /// Silent capture when allowed; otherwise ask once for permission and fall back to ⌘⌃⇧4.
    /// Calls back only with a picture; failures end up as the answer text.
    private func grabScreen(_ completion: @escaping (URL) -> Void) {
        if ScreenGrab.hasAccess {
            ScreenGrab.capture { [weak self] url in
                if let url { completion(url) } else { self?.waitForClipboard(completion) }
            }
        } else {
            ScreenGrab.requestAccessOnce()
            waitForClipboard(completion)
        }
    }

    private func waitForClipboard(_ completion: @escaping (URL) -> Void) {
        guard chatOpen else { return }
        model.chatAwaitingClip = true
        let pb = NSPasteboard.general
        let start = pb.changeCount, deadline = Date().addingTimeInterval(60)
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if pb.changeCount != start, let url = ScreenGrab.fromPasteboard(pb) {
                self.stopClipWatch()
                completion(url)
            } else if Date() > deadline {
                self.stopClipWatch()
                self.fail(L10n.ui(.screenNoImage))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        clipWatch = t
    }

    private func stopClipWatch() {
        clipWatch?.invalidate()
        clipWatch = nil
        model.chatAwaitingClip = false
    }

    /// Sends the question with whatever this chat is about: a dropped file, the latest screenshot.
    private func run(_ question: String, prompt custom: String?) {
        var prompt = custom ?? Self.chatPrompt(history: chatHistory, question: question)
        var files: [URL] = []
        if let f = chatFile {
            files.append(f.url)
            if custom == nil {
                prompt = "Earlier the user dropped the file \(f.name) into this chat; it is in the current folder. "
                    + "Read it again if the question needs it.\(f.hint)\n\n" + prompt
            }
        }
        if let shot = screenshot {
            files.append(shot)
            prompt = "The user attached a screenshot of their screen: \(shot.lastPathComponent) in the current folder. "
                + "Read it before answering. If they only ask what's on screen, describe it in 2-4 sentences: "
                + "which app, what they're doing, and any error or problem you can see.\n\n" + prompt
        }
        runner.ask(prompt, files: files, onText: { [weak self] partial in
            guard let self, self.chatOpen else { return }
            self.model.chatAnswer = partial
            self.chatPhase = .answer
        }, onDone: { [weak self] result in
            guard let self, self.chatOpen else { return }
            switch result {
            case .success(let answer):
                self.model.chatAnswer = answer
                self.chatHistory.append((question, answer))
            case .failure(let f):
                self.model.chatAnswer = f.message
                self.model.chatError = true
            }
            self.chatPhase = .answer
            self.panel.makeKey()
            if let f = self.model.chatField { self.panel.makeFirstResponder(f) }
        })
    }

    private func fail(_ message: String) {
        model.chatAnswer = message
        model.chatError = true
        chatPhase = .answer
    }

    // MARK: Files

    /// A file landed on the notch: sum it up in the chat, then keep it for follow-up questions.
    private func dropped(_ url: URL) -> Bool {
        dragFile = nil
        if !chatOpen { openChat() }
        guard chatOpen else { return false }
        runner.cancel()
        FileDrop.discard(chatFile)
        chatFile = nil
        setScreenshot(nil)
        chatHistory = []
        chatPhase = .input
        guard let file = FileDrop.prepare(url) else {
            model.chatQuestion = url.lastPathComponent
            model.chatNote = ""
            fail(L10n.ui(FileDrop.kind(of: url) == nil ? .fileUnsupportedLong : .fileUnreadable))
            return true
        }
        chatFile = file
        model.chatNote = file.note ?? ""
        let lang = L10n.lang == .ru ? "Russian" : "English"
        let prompt = "The user dropped a file into the notch: \(file.name), in the current folder. Read it and sum it up "
            + "in 3-5 sentences: what it is and its main points.\(file.hint) Reply in \(lang)."
        ask(L10n.fileSummaryQuestion(file.name), prompt: prompt)
        return true
    }

    /// Polls instead of watching events: no permissions needed. A drag shows up as the left button
    /// held down while the drag pasteboard gets new contents.
    private func updateDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            dragBaseline = dragPasteboard.changeCount
            dragFile = nil
            return
        }
        guard dragFile == nil, dragPasteboard.changeCount != dragBaseline else { return }
        dragBaseline = dragPasteboard.changeCount
        dragFile = NotchHostingView.fileURL(dragPasteboard)
        if let url = dragFile {
            model.dragLabel = url.lastPathComponent
            model.dragSupported = FileDrop.looksSupported(url)
        }
    }

    /// The area near the top of the screen where a dragged file opens the notch.
    private func dropZone() -> NSRect {
        NSRect(x: panel.frame.width / 2 - 220, y: -2, width: 440, height: model.notchHeight + 90)
    }

    /// The CLI call is stateless, so earlier turns of this chat ride along in the prompt.
    private static func chatPrompt(history: [(question: String, answer: String)], question: String) -> String {
        guard !history.isEmpty else { return question }
        let past = history.map { "User: \($0.question)\nClawd: \($0.answer)" }.joined(separator: "\n\n")
        return "Earlier in this chat:\n\n\(past)\n\n---\nThe user's new message:\n\(question)"
    }

    // MARK: Demo

    /// Every notch state in turn (Settings / menu "Play demo"). Real events still drive the crab,
    /// so the wings, outline, Done card and sleep look exactly as they do for real.
    func playDemo() {
        guard isShown, !hiddenForFullscreen else { return }
        closeChat()
        dismissApproval()
        stopDemo()
        let ru = L10n.lang == .ru
        let steps: [(TimeInterval, () -> Void)] = [
            (1.6, { self.brain.handle(["event": "SessionStart"]); self.demoState = .compact }),
            (2.4, { self.demoState = .hover }),
            (2.6, { self.brain.handle(["event": "PreToolUse", "tool": "Edit", "detail": "App.swift"]); self.demoState = .wings }),
            (2.6, { self.brain.handle(["event": "PreToolUse", "tool": "Bash", "detail": "npm test"]); self.demoState = .wings }),
            (3.2, {
                self.model.approvalTitle = L10n.approvalTitle(tool: "Bash")
                self.model.approvalDetail = "rm -rf node_modules && npm install"
                self.model.approvalLines = 1
                self.model.approvalFits = true
                self.model.approvalSince = Date()
                self.brain.handle(["event": "Notification", "kind": "permission_prompt"])
                self.demoState = .approval
            }),
            (2.2, { self.brain.handle(["event": "PostToolUseFailure", "tool": "Bash"]); self.demoState = .wings }),
            (3.0, { self.brain.handle(["event": "Stop"]); self.demoState = .done }),
            (2.4, {
                self.model.chatQuestion = ru ? "Как отменить последний коммит?" : "How do I undo my last commit?"
                self.model.chatLookingAtScreen = false
                self.model.chatAwaitingClip = false
                self.demoState = .chatThinking
            }),
            (4.0, {
                self.model.chatAnswer = ru
                    ? "Если коммит ещё не отправлен, выполни `git reset --soft HEAD~1`: коммит исчезнет, а изменения останутся в файлах."
                    : "If it isn't pushed yet, run `git reset --soft HEAD~1`: the commit goes away and your changes stay in the files."
                self.model.chatError = false
                self.model.chatNote = ""
                self.demoState = .chatAnswer
            }),
            (2.6, { self.model.dragLabel = "README.md"; self.model.dragSupported = true; self.demoState = .fileOver }),
            (3.0, { self.brain.sleepNow(); self.demoState = .sleeping }),
        ]
        var at: TimeInterval = 0
        for (duration, step) in steps {
            demoAfter(at, step)
            at += duration
        }
        demoAfter(at) { self.stopDemo() }
    }

    private func demoAfter(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            if self != nil { block() }
        }
        RunLoop.main.add(t, forMode: .common)
        demoTimers.append(t)
    }

    private func stopDemo() {
        demoTimers.forEach { $0.invalidate() }
        demoTimers = []
        guard demoState != nil else { return }
        demoState = nil
        if !chatOpen {
            model.chatQuestion = ""
            model.chatAnswer = ""
            model.chatAnswerHeight = 0
        }
    }

    // MARK: Geometry

    /// The built-in display with the cutout if there is one, otherwise the menu bar screen.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func layout() {
        guard let screen else { return }
        let f = screen.frame
        var notchWidth: CGFloat = 185, notchHeight = f.maxY - screen.visibleFrame.maxY
        var centerX = f.midX
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = f.width - left.width - right.width
            notchHeight = screen.safeAreaInsets.top
            centerX = f.minX + (left.width + f.width - right.width) / 2
        }
        if notchHeight <= 0 { notchHeight = 24 }  // menu bar set to auto-hide
        model.notchWidth = notchWidth
        model.notchHeight = notchHeight

        // Long answers get most of the screen so they show in full instead of scrolling.
        model.chatAnswerMaxExtra = max(260, (f.height * chatAnswerScreenShare - notchHeight).rounded(.down))
        let extra = max(NotchStyle.canvasExtraHeight, model.chatAnswerMaxExtra + 24)
        let size = NSSize(width: NotchStyle.canvasWidth, height: notchHeight + extra)
        panel.setFrame(NSRect(x: (centerX - size.width / 2).rounded(), y: f.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// Where the island currently is (its target size, shoulders included), in panel coordinates
    /// with the origin at the top-left.
    private func islandRect() -> NSRect {
        let s = model.size
        let w = s.width + 2 * NotchStyle.shoulder
        return NSRect(x: (panel.frame.width - w) / 2, y: 0, width: w, height: s.height)
    }

    // MARK: Tick

    private func tick() {
        ticks += 1
        if ticks % 30 == 0 { checkFullscreen() }
        syncWithBuddy()
        guard !hiddenForFullscreen else { return }

        let m = NSEvent.mouseLocation
        let local = NSPoint(x: m.x - panel.frame.minX, y: panel.frame.maxY - m.y)
        // A little slack, and the very top edge of the screen counts as inside.
        updateDrag()
        let dragHere = dragFile != nil && dropZone().contains(local)
        let r = islandRect()
        let inside = NSRect(x: r.minX - 2, y: r.minY - 2, width: r.width + 4, height: r.height + 2).contains(local)

        if inside {
            outsideSince = nil
            hovering = true
        } else if hovering {
            // Short grace period so brushing past the edge doesn't snap it shut.
            if let since = outsideSince {
                if Date().timeIntervalSince(since) > 0.25 { outsideSince = nil; hovering = false }
            } else {
                outsideSince = Date()
            }
        }
        // Most urgent first: a permission request, then the chat, then hover.
        set(approval != nil ? .approval : dragHere ? .fileOver : demoState ?? (chatOpen ? chatState : hovering ? .hover : restingState))
        updateOutline()

        let ignore = !inside && !dragHere
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// What the island shows when the mouse isn't on it.
    private var restingState: NotchState {
        if let d = doneUntil, Date() < d { return .done }
        switch buddy.mood {
        case .idle, .done: return .compact
        case .sleeping: return prefs.hideWhenSleeping ? .compact : .sleeping
        default: return .wings
        }
    }

    /// Follows the corner buddy's mood and lines (Brain drives both modes).
    private func syncWithBuddy() {
        let mood = buddy.mood
        if mood != lastMood {
            lastMood = mood
            model.activity = Self.activity(for: mood)
            model.activitySince = Date()
            switch mood {
            case .done:
                doneUntil = Date().addingTimeInterval(3)
                model.doneAt = Date()
                model.doneStats = L10n.turnStats(edits: brain.lastTurn.edits, duration: brain.lastTurn.duration)
                flash(NotchStyle.green, 1.6)
            case .oops:
                flash(NotchStyle.yellow, 1.1)
            default:
                break
            }
        }
        let line = buddy.bubbleText
        if !line.isEmpty, line != model.title { model.title = line }
        let status = L10n.status(mood)
        if status != model.subtitle { model.subtitle = status }
    }

    private static func activity(for mood: Mood) -> NotchActivity {
        switch mood {
        case .writing: return .writing
        case .running, .agent: return .running
        case .reading: return .reading
        case .searching: return .searching
        case .web: return .web
        case .waiting: return .waiting
        case .oops: return .oops
        case .sleeping: return .sleeping
        case .idle, .thinking, .done: return .thinking
        }
    }

    private func flash(_ color: Color, _ duration: TimeInterval) {
        guard prefs.notchOutline else { return }
        let f = NotchFlash(color: color, start: Date(), duration: duration)
        model.flash = f
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.model.flash == f { self?.model.flash = nil }
        }
    }

    /// Comet while Claude works, breathing orange while it waits for you; nothing on hover or at rest.
    private func updateOutline() {
        var o = NotchOutline.none
        if prefs.notchOutline && (model.state == .approval || model.state == .fileOver) {
            o = .breathe
        } else if prefs.notchOutline && model.state == .wings {
            switch buddy.mood {
            case .writing, .reading, .searching, .running, .web, .agent, .thinking: o = .comet
            case .waiting: o = .breathe
            default: break
            }
        }
        if o != model.outline { model.outline = o }
    }

    // MARK: Full screen

    private func checkFullscreen() {
        guard isShown, let screen else { return }
        let hide = prefs.hideInFullscreen && frontmostCoversScreen(screen)
        guard hide != hiddenForFullscreen else { return }
        hiddenForFullscreen = hide
        if hide { closeChat(); set(.compact); panel.ignoresMouseEvents = true }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = hide ? 0 : 1
        }
    }

    /// True when the active app has a window covering the whole screen, menu bar area included:
    /// native full screen, games and video players. Window bounds don't need Screen Recording.
    private func frontmostCoversScreen(_ screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        // CoreGraphics measures from the top-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds.insetBy(dx: -1, dy: -1).contains(target)
        }
    }
}
