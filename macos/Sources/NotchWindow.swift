import AppKit
import SwiftUI

/// Clicks on a panel that never becomes key must still reach the buttons on the first try.
private final class NotchHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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
    private var hiddenForFullscreen = false
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
        panel.contentView = NotchHostingView(rootView: NotchRootView(model: model))
        model.onApprovalAnswer = { [weak self] in self?.answerApproval($0) }
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
        dismissApproval()
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
        approval = ticket
        model.approvalTitle = L10n.approvalTitle(tool: ticket.request.tool)
        model.approvalDetail = ticket.request.detail
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
        ticket.answer(decision)
        closeApproval()
        if decision != .terminal { brain.permissionAnswered() }
    }

    private func closeApproval() {
        approval = nil
        approvalTimer?.invalidate()
        approvalTimer = nil
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

        let size = NSSize(width: NotchStyle.canvasWidth, height: notchHeight + NotchStyle.canvasExtraHeight)
        panel.setFrame(NSRect(x: (centerX - size.width / 2).rounded(), y: f.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// Where the island currently is (its target size, shoulders included), in panel coordinates
    /// with the origin at the top-left.
    private func islandRect(for state: NotchState) -> NSRect {
        let s = NotchModel.size(of: state, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
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
        let r = islandRect(for: model.state)
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
        set(approval != nil ? .approval : hovering ? .hover : restingState)
        updateOutline()

        let ignore = !inside
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
        if prefs.notchOutline && model.state == .approval {
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
        if hide { set(.compact); panel.ignoresMouseEvents = true }
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
