import AppKit
import SwiftUI

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
    let model = NotchModel()
    private let prefs: Prefs
    private var panel: NotchPanel!
    private var timer: Timer?
    private var ticks = 0
    private var outsideSince: Date?
    private var hiddenForFullscreen = false
    private var observers: [NSObjectProtocol] = []
    private(set) var isShown = false

    init(prefs: Prefs) {
        self.prefs = prefs
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchRootView(model: model))
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
        panel.orderOut(nil)
        model.state = .compact
    }

    func applyPrefs() {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !prefs.hideInFullscreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior
        if isShown { checkFullscreen() }
    }

    func set(_ state: NotchState) {
        guard state != model.state else { return }
        withAnimation(NotchStyle.spring) { model.state = state }
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
        guard !hiddenForFullscreen else { return }

        let m = NSEvent.mouseLocation
        let local = NSPoint(x: m.x - panel.frame.minX, y: panel.frame.maxY - m.y)
        // A little slack, and the very top edge of the screen counts as inside.
        let r = islandRect(for: model.state)
        let inside = NSRect(x: r.minX - 2, y: r.minY - 2, width: r.width + 4, height: r.height + 2).contains(local)

        switch model.state {
        case .compact, .sleeping:
            if inside { set(.hover) }
        case .hover:
            if inside {
                outsideSince = nil
            } else if let since = outsideSince {
                if Date().timeIntervalSince(since) > 0.25 { outsideSince = nil; set(.compact) }
            } else {
                outsideSince = Date()
            }
        default:
            break
        }

        let ignore = !inside
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
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
