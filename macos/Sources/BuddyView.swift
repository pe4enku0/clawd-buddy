import AppKit

enum Mood { case idle, thinking, writing, reading, searching, running, web, agent, waiting, done, sleeping, oops }

/// Short idle routines, played on top of the idle mood.
enum Act: CaseIterable { case lookAround, stretch, dance, hop, wave, yawn, wiggle }

private enum Eyes { case open, closed, happy, lookLeft, lookRight, lookUp, lookDown, wide, squint }
private enum Arm { case down, low, up }
private enum Legs { case stand, splay }
private enum Prop { case none, laptop, paper }

private struct Pose {
    var eyes: Eyes = .open
    var lArm: Arm = .down
    var rArm: Arm = .down
    var legs: Legs = .stand
    var prop: Prop = .none
    var crouch = 0          // 0/1 grid rows, body sinks onto the legs
    var dx = 0              // grid columns
    var lift: CGFloat = 0   // grid rows, from jumps
    var paperScroll = 0
}

private struct Particle {
    var text: String
    var x: CGFloat, y: CGFloat
    var vx: CGFloat, vy: CGFloat
    var g: CGFloat = 0
    var life: CGFloat
    let maxLife: CGFloat
    let color: NSColor
    var size: CGFloat = 12
    var outlined = true
}

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

enum Palette {
    static let body = rgb(0xD97757)
    static let shade = rgb(0xC36548)
    static let legs = rgb(0xB0583D)
    static let eye = rgb(0x1F1410)
    static let ink = rgb(0x2B1C17)
    static let ivory = rgb(0xFAF9F5)
    static let lid = rgb(0x3D3D3A), lidEdge = rgb(0x55544E), keyboard = rgb(0xB9B5AA), keyboardShade = rgb(0x9C988D)
    static let paperLine = rgb(0xB9B5AA), paperEdge = rgb(0xE3DED3)
    static let confetti = [rgb(0xD97757), rgb(0xE8B04B), rgb(0x6A9BCC), rgb(0x7FB77E), rgb(0xC46686)]

    // Claude-style bubble
    static func claudeFill(_ dark: Bool) -> NSColor { dark ? rgb(0x30302E) : rgb(0xFAF9F5) }
    static func claudeBorder(_ dark: Bool) -> NSColor { dark ? rgb(0x4A4945) : rgb(0xDEDAD0) }
    static func claudeText(_ dark: Bool) -> NSColor { dark ? rgb(0xF5F4EF) : rgb(0x141413) }
}

/// Draws the pixel crab, its speech bubble and floating particles. All animation is tick-driven (30 fps).
final class BuddyView: NSView {
    static let unit: CGFloat = 6
    static let gridW = 14, gridH = 10
    static let size = NSSize(width: 380, height: 136)

    var onPoke: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDropped: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    var style: BubbleStyle = .pixel { didSet { measureBubble() } }
    var followMouse = true
    /// Mouse position in view coordinates, fed by the app every tick (may lie outside the view).
    var mouse: NSPoint?

    private(set) var mood: Mood = .idle
    private(set) var isDragging = false
    var isActing: Bool { act != nil }

    private var tick = 0, moodTick = 0
    private var blinkUntil = 0, nextBlink = 90
    private var jumpStart = -100, jumpLen = 14
    private var jumpHeight: CGFloat = 4
    private var pokeUntil = 0, squishUntil = 0
    private var act: Act?
    private var actTick = 0
    private var particles: [Particle] = []

    /// The last thing the crab said.
    private(set) var bubbleText = ""
    private var bubbleChars: [Character] = []
    private var bubbleShown = 0
    private var bubbleShowing = false
    private var bubbleAlpha: CGFloat = 0
    private var bubbleTextSize = NSSize.zero

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragMoved = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var crabOrigin: NSPoint {
        NSPoint(x: Self.size.width - CGFloat(Self.gridW) * Self.unit - 14, y: 52)
    }
    private var eyeLevel: CGFloat { crabOrigin.y + 3 * Self.unit }
    /// Between the eyes; mouse positions are judged from here.
    var eyeAnchor: NSPoint { NSPoint(x: crabOrigin.x + 7 * Self.unit, y: eyeLevel) }

    private var crabRect: NSRect {
        let o = crabOrigin
        return NSRect(x: o.x - 4, y: o.y - 30, width: CGFloat(Self.gridW) * Self.unit + 8,
                      height: CGFloat(Self.gridH) * Self.unit + 34)
    }

    private var padding: NSSize { style == .pixel ? NSSize(width: 10, height: 7) : NSSize(width: 13, height: 9) }
    private var headerHeight: CGFloat { style == .claude ? 15 : 0 }

    private var bubbleRect: NSRect {
        let w = bubbleTextSize.width + padding.width * 2
        let h = bubbleTextSize.height + padding.height * 2 + headerHeight
        let right = crabOrigin.x - 12
        let top = max(4, eyeLevel - h / 2)
        return NSRect(x: right - w, y: top, width: w, height: h)
    }

    private var hovering: Bool { mouse.map { crabRect.contains($0) } ?? false }

    func isInteractive(at p: NSPoint) -> Bool {
        crabRect.contains(p) || (bubbleShowing && bubbleRect.insetBy(dx: -2, dy: -2).contains(p))
    }

    // MARK: Control

    func setMood(_ m: Mood) {
        guard m != mood else { return }
        mood = m
        moodTick = 0
        act = nil
        if m == .done { burstConfetti() }
    }

    func jump(_ height: CGFloat = 4) {
        jumpStart = tick
        jumpHeight = height
        jumpLen = Int(10 + height * 1.5)
    }

    func play(_ a: Act) {
        act = a
        actTick = 0
        if a == .hop { jump(3) }
    }

    func say(_ text: String) {
        bubbleText = text
        bubbleChars = Array(text)
        bubbleShown = 0
        bubbleShowing = true
        measureBubble()
    }

    func hideBubble() { bubbleShowing = false }

    private func measureBubble() {
        let r = (bubbleText as NSString).boundingRect(
            with: NSSize(width: 230, height: 200), options: [.usesLineFragmentOrigin], attributes: textAttrs)
        bubbleTextSize = NSSize(width: max(ceil(r.width), style == .claude ? 40 : 0), height: ceil(r.height))
    }

    // MARK: Animation

    private static let actLength: [Act: Int] = [
        .lookAround: 72, .stretch: 50, .dance: 72, .hop: 36, .wave: 48, .yawn: 40, .wiggle: 30,
    ]

    func step() {
        tick += 1
        moodTick += 1

        if tick >= nextBlink {
            blinkUntil = tick + 4
            nextBlink = tick + Int.random(in: 70...170)
        }
        if mood == .waiting && moodTick % 60 == 1 { jump(2.5) }

        if let a = act {
            actTick += 1
            if a == .hop && actTick == 18 { jump(2.5) }
            if a == .dance && actTick % 12 == 1 { emit(["♪", "♫"], Palette.body) }
            if actTick >= Self.actLength[a] ?? 40 { act = nil }
        }

        spawnParticles()
        particles = particles.compactMap { p in
            var p = p
            p.vy += p.g
            p.x += p.vx; p.y += p.vy; p.life -= 1
            return p.life > 0 ? p : nil
        }

        if bubbleShowing {
            bubbleAlpha = min(1, bubbleAlpha + 0.2)
            if bubbleShown < bubbleChars.count {
                bubbleShown = min(bubbleChars.count, bubbleShown + (bubbleChars.count > 40 ? 2 : 1))
            }
        } else {
            bubbleAlpha = max(0, bubbleAlpha - 0.12)
        }

        // Hidden (notch mode keeps animating it off screen) or sleeping with nothing moving: no need for 30 fps.
        guard window?.isVisible == true else { return }
        if mood != .sleeping || !particles.isEmpty || bubbleAlpha > 0 || tick % 3 == 0 {
            needsDisplay = true
        }
    }

    private func spawnParticles() {
        let t = moodTick
        func every(_ n: Int) -> Bool { t % n == 1 }
        switch mood {
        case .writing: if every(9) { emit(["{ }", ";", "</>", "()", "=>", "#", "[ ]"], Palette.body) }
        case .thinking: if every(32) { emit(["?", "…", "?"], Palette.ink) }
        case .running: if every(14) { emit([">_", "⚡", "⚙"], Palette.body) }
        case .agent: if every(20) { emit(["🦀", "⚡"], Palette.body) }
        case .searching: if every(26) { emit(["🔍"], Palette.ink) }
        case .web: if every(26) { emit(["🌐"], Palette.ink) }
        case .waiting: if every(30) { emit(["!"], Palette.body) }
        case .done: if t < 70 && every(5) { emit(["✦", "✧", "★"], Palette.body) }
        case .sleeping: if every(40) { emit(["z", "Z"], Palette.ink) }
        case .oops: if every(40) { emit(["💦"], Palette.ink) }
        case .reading: if every(60) { emit(["📖"], Palette.ink) }
        case .idle: break
        }
    }

    private func emit(_ texts: [String], _ color: NSColor) {
        let o = crabOrigin
        particles.append(Particle(
            text: texts.randomElement()!,
            x: o.x + CGFloat.random(in: 12...64), y: o.y - 6,
            vx: CGFloat.random(in: -0.7...0.15), vy: -CGFloat.random(in: 0.45...0.85),
            life: 52, maxLife: 52, color: color))
    }

    private func burstConfetti() {
        let o = crabOrigin
        for _ in 0..<22 {
            particles.append(Particle(
                text: ["■", "●", "▲", "✦"].randomElement()!,
                x: o.x + CGFloat.random(in: 20...60), y: o.y + 6,
                vx: CGFloat.random(in: -2.6...1.0), vy: -CGFloat.random(in: 2.2...4.2), g: 0.13,
                life: 64, maxLife: 64, color: Palette.confetti.randomElement()!,
                size: CGFloat.random(in: 7...10), outlined: false))
        }
    }

    private func eyesToward(_ m: NSPoint) -> Eyes {
        let cx = crabOrigin.x + 7 * Self.unit, cy = eyeLevel
        let dx = m.x - cx, dy = m.y - cy
        if hypot(dx, dy) > 700 || (abs(dx) < 20 && abs(dy) < 20) { return .open }
        if abs(dy) > abs(dx) * 1.3 { return dy < 0 ? .lookUp : .lookDown }
        return dx < 0 ? .lookLeft : .lookRight
    }

    private func currentPose() -> Pose {
        var p = Pose()
        let t = moodTick
        var follow = false
        switch mood {
        case .idle:
            p.crouch = (t / 26) % 2
            follow = true
        case .thinking:
            p.crouch = (t / 20) % 2
            p.eyes = (t / 25) % 2 == 0 ? .lookUp : .lookLeft
            p.lArm = .low
        case .writing:
            let f = (t / 4) % 2
            p.lArm = f == 0 ? .down : .low
            p.rArm = f == 0 ? .low : .down
            p.prop = .laptop
            p.eyes = (t / 40) % 4 == 3 ? .lookLeft : .lookDown
        case .reading:
            p.prop = .paper
            p.lArm = .low; p.rArm = .low
            p.eyes = (t / 14) % 2 == 0 ? .lookDown : .open
            p.crouch = (t / 30) % 2
            p.paperScroll = (t / 15) % 2
        case .searching, .web:
            p.legs = (t / 4) % 2 == 0 ? .stand : .splay
            p.dx = [0, -1, 0, 1][(t / 6) % 4]
            p.eyes = (t / 12) % 2 == 0 ? .lookLeft : .lookRight
        case .running, .agent:
            p.legs = (t / 3) % 2 == 0 ? .stand : .splay
            p.crouch = (t / 6) % 2
            p.lArm = (t / 6) % 2 == 0 ? .low : .down
            p.rArm = (t / 6) % 2 == 0 ? .down : .low
        case .waiting:
            p.lArm = (t / 8) % 2 == 0 ? .up : .down
            p.eyes = .wide
            follow = true
        case .done:
            p.eyes = .happy
            if t < 60 { p.lArm = .up; p.rArm = .up }
            p.crouch = (t / 15) % 2
        case .sleeping:
            p.eyes = .closed
            p.crouch = (t / 45) % 2 == 0 ? 1 : 0
        case .oops:
            p.eyes = .squint
            p.crouch = 1
            p.lArm = .low; p.rArm = .low
            if t < 18 { p.dx = (t / 2) % 2 == 0 ? -1 : 1 }
        }

        if let a = act {
            let at = actTick
            switch a {
            case .lookAround:
                p.eyes = at < 18 ? .lookLeft : at < 26 ? .open : at < 44 ? .lookRight : at < 58 ? .lookUp : .open
            case .stretch:
                if at < 8 { p.crouch = 1 } else if at < 42 { p.crouch = 0; p.lArm = .up; p.rArm = .up; p.eyes = .closed }
            case .dance:
                let beat = at / 6
                p.dx = [-1, 0, 1, 0][beat % 4]
                p.lArm = beat % 2 == 0 ? .up : .down
                p.rArm = beat % 2 == 0 ? .down : .up
                p.legs = beat % 2 == 0 ? .splay : .stand
                p.eyes = .happy
            case .hop:
                p.eyes = .happy
            case .wave:
                p.lArm = (at / 7) % 2 == 0 ? .up : .down
                p.eyes = .happy
            case .yawn:
                p.eyes = .closed; p.crouch = 1; p.lArm = .low; p.rArm = .low
            case .wiggle:
                p.dx = [0, 1, 0, -1][(at / 3) % 4]
                p.eyes = .happy
            }
            follow = false
        }

        if follow && followMouse, let m = mouse { p.eyes = eyesToward(m) }
        if hovering && !isDragging && (mood == .idle || mood == .done) && act == nil { p.eyes = .happy }
        if tick < blinkUntil && [.open, .lookLeft, .lookRight, .lookUp, .lookDown, .wide].contains(p.eyes) { p.eyes = .closed }
        if tick < pokeUntil { p.eyes = .wide; p.lArm = .up; p.rArm = .up }

        if isDragging && dragMoved {
            p.legs = (tick / 3) % 2 == 0 ? .stand : .splay
            p.eyes = .wide
            p.lArm = (tick / 4) % 2 == 0 ? .up : .low
            p.rArm = (tick / 4) % 2 == 0 ? .low : .up
            p.prop = .none
            p.crouch = 0
            p.dx = 0
        }

        let jt = tick - jumpStart
        if jt >= 0 && jt < jumpLen {
            p.lift = sin(.pi * CGFloat(jt) / CGFloat(jumpLen)) * jumpHeight
            p.crouch = 0
        } else if jt >= jumpLen && jt < jumpLen + 3 || tick < squishUntil {
            p.crouch = 1 // landing squish
        }
        return p
    }

    // MARK: Drawing

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private var textAttrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        if style == .pixel {
            para.lineSpacing = 1
            return [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: Palette.ink, .paragraphStyle: para]
        }
        para.lineSpacing = 2
        let base = NSFont.systemFont(ofSize: 13.5)
        let serif = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 13.5) } ?? base
        return [.font: serif, .foregroundColor: Palette.claudeText(isDark), .paragraphStyle: para]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pose = currentPose()
        drawShadow(pose)
        drawParticles()
        ctx.setShouldAntialias(false)
        drawCrab(pose, ctx: ctx)
        ctx.setShouldAntialias(true)
        if bubbleAlpha > 0.01 && !bubbleChars.isEmpty {
            style == .pixel ? drawPixelBubble(ctx: ctx) : drawClaudeBubble(ctx: ctx)
        }
    }

    private func drawShadow(_ p: Pose) {
        let u = Self.unit, o = crabOrigin
        let w = 10 * u - p.lift * 5
        let r = NSRect(x: o.x + 7 * u - w / 2 + CGFloat(p.dx) * u, y: o.y + 10 * u - 1, width: w, height: 6)
        NSColor.black.withAlphaComponent(max(0.05, 0.22 - p.lift * 0.02)).setFill()
        NSBezierPath(ovalIn: r).fill()
    }

    private func drawCrab(_ p: Pose, ctx: CGContext) {
        let o = crabOrigin
        let at = NSPoint(x: o.x + CGFloat(p.dx) * Self.unit, y: o.y - (p.lift * Self.unit).rounded())
        // soft drop shadow so the crab reads on any wallpaper
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        Self.paint(p, at: at, unit: Self.unit)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Draws the crab as it looks right now (mood, act, jump) at another size, e.g. in the notch.
    /// Flipped context; `origin` is the top-left grid cell.
    func paintCrab(at origin: NSPoint, unit u: CGFloat) {
        let p = currentPose()
        Self.paint(p, at: NSPoint(x: origin.x + CGFloat(p.dx) * u, y: origin.y - (p.lift * u).rounded()), unit: u)
    }

    /// The thinking pose on its own, for the notch chat (whatever Claude Code is doing meanwhile).
    static func paintThinking(at origin: NSPoint, unit u: CGFloat, tick t: Int) {
        var p = Pose()
        p.crouch = (t / 20) % 2
        p.eyes = (t / 25) % 2 == 0 ? .lookUp : .lookLeft
        p.lArm = .low
        paint(p, at: origin, unit: u)
    }

    /// Happy waving, for the notch's file-drop card.
    static func paintWaving(at origin: NSPoint, unit u: CGFloat, tick t: Int) {
        var p = Pose()
        p.eyes = .happy
        p.lArm = (t / 7) % 2 == 0 ? .up : .down
        paint(p, at: origin, unit: u)
    }

    /// Paints a pose into a flipped context with its top-left grid cell at `at`.
    fileprivate static func paint(_ p: Pose, at: NSPoint, unit u: CGFloat) {
        func fill(_ c: Int, _ r: Int, _ w: Int = 1, _ h: Int = 1, _ color: NSColor) {
            color.setFill()
            NSRect(x: at.x + CGFloat(c) * u, y: at.y + CGFloat(r) * u, width: CGFloat(w) * u, height: CGFloat(h) * u).fill()
        }

        for c in (p.legs == .stand ? [3, 5, 8, 10] : [2, 4, 9, 11]) { fill(c, 8, 1, 2, Palette.legs) }

        let cr = p.crouch
        fill(2, cr, 10, 8, Palette.body)
        fill(2, 7 + cr, 10, 1, Palette.shade)

        for (left, arm) in [(true, p.lArm), (false, p.rArm)] {
            let cells: [(Int, Int)]
            switch arm {
            case .down: cells = [(0, 4), (1, 4), (0, 5), (1, 5)]
            case .low: cells = [(0, 5), (1, 5), (0, 6), (1, 6)]
            case .up: cells = [(1, 3), (0, 2), (1, 2), (0, 1)]
            }
            for (c, r) in cells { fill(left ? c : 13 - c, r + cr, 1, 1, Palette.body) }
        }

        let eyeCells: [(Int, Int)]
        switch p.eyes {
        case .open: eyeCells = [(0, 2), (0, 3)]
        case .lookLeft: eyeCells = [(-1, 2), (-1, 3)]
        case .lookRight: eyeCells = [(1, 2), (1, 3)]
        case .lookUp: eyeCells = [(0, 1), (0, 2)]
        case .lookDown: eyeCells = [(0, 3), (0, 4)]
        case .closed: eyeCells = [(-1, 3), (0, 3), (1, 3)]
        case .happy: eyeCells = [(-1, 3), (-1, 2), (0, 2), (1, 2), (1, 3)]
        case .wide: eyeCells = [(0, 1), (0, 2), (0, 3)]
        case .squint: eyeCells = [(-1, 3), (0, 3)]
        }
        for center in [4, 9] {
            for (dc, r) in eyeCells { fill(center + dc, r + cr, 1, 1, Palette.eye) }
        }

        switch p.prop {
        case .none:
            break
        case .laptop:
            // back of the lid facing us, keyboard base underneath
            fill(3, 5, 8, 3, Palette.lid)
            fill(3, 5, 8, 1, Palette.lidEdge)
            fill(7, 6, 1, 1, Palette.confetti[1])
            fill(2, 8, 10, 1, Palette.keyboard)
            fill(2, 9, 10, 1, Palette.keyboardShade)
        case .paper:
            fill(4, 5 + cr, 6, 4, Palette.ivory)
            fill(9, 5 + cr, 1, 4, Palette.paperEdge)
            let lines = p.paperScroll == 0 ? [(6, 4), (7, 3)] : [(6, 3), (7, 4)]
            for (r, w) in lines { fill(5, r + cr, w, 1, Palette.paperLine) }
        }
    }

    /// Rectangle with square-notched corners, for a pixel-art look.
    private func pixelBox(_ r: NSRect, notch n: CGFloat = 3) -> NSBezierPath {
        let (x, y, X, Y) = (r.minX, r.minY, r.maxX, r.maxY)
        let pts = [(x + n, y), (X - n, y), (X - n, y + n), (X, y + n), (X, Y - n), (X - n, Y - n),
                   (X - n, Y), (x + n, Y), (x + n, Y - n), (x, Y - n), (x, y + n), (x + n, y + n)]
        let path = NSBezierPath()
        path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
        path.close()
        return path
    }

    private var visibleText: String { String(bubbleChars.prefix(bubbleShown)) }

    private func drawPixelBubble(ctx: CGContext) {
        let r = bubbleRect.offsetBy(dx: (1 - bubbleAlpha) * 6, dy: 0)
        let X = r.maxX, ty = eyeLevel

        ctx.saveGState()
        ctx.setAlpha(bubbleAlpha)

        NSColor.black.withAlphaComponent(0.25).setFill()
        pixelBox(r.offsetBy(dx: 3, dy: 3)).fill()
        NSRect(x: X + 1, y: ty - 4, width: 9, height: 8).fill()

        Palette.ink.setFill()
        pixelBox(r).fill()
        NSRect(x: X - 2, y: ty - 7, width: 7, height: 14).fill()
        NSRect(x: X + 5, y: ty - 4, width: 5, height: 8).fill()

        Palette.ivory.setFill()
        pixelBox(r.insetBy(dx: 2, dy: 2), notch: 2).fill()
        NSRect(x: X - 4, y: ty - 5, width: 7, height: 10).fill()
        NSRect(x: X + 3, y: ty - 2, width: 5, height: 4).fill()

        (visibleText as NSString).draw(
            with: NSRect(x: r.minX + padding.width, y: r.minY + padding.height,
                         width: bubbleTextSize.width + 1, height: bubbleTextSize.height + 2),
            options: [.usesLineFragmentOrigin], attributes: textAttrs)
        ctx.restoreGState()
    }

    private func drawClaudeBubble(ctx: CGContext) {
        let dark = isDark
        let r = bubbleRect.offsetBy(dx: (1 - bubbleAlpha) * 6, dy: 0)
        let (x, y, X, Y) = (r.minX, r.minY, r.maxX, r.maxY)
        let rad: CGFloat = 12, ty = eyeLevel

        // rounded rect with a soft tail on the right edge pointing at the crab
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + rad, y: y))
        path.appendArc(from: NSPoint(x: X, y: y), to: NSPoint(x: X, y: Y), radius: rad)
        path.line(to: NSPoint(x: X, y: ty - 6))
        path.curve(to: NSPoint(x: X + 9, y: ty), controlPoint1: NSPoint(x: X + 3, y: ty - 3), controlPoint2: NSPoint(x: X + 7, y: ty - 1))
        path.curve(to: NSPoint(x: X, y: ty + 6), controlPoint1: NSPoint(x: X + 7, y: ty + 1), controlPoint2: NSPoint(x: X + 3, y: ty + 3))
        path.appendArc(from: NSPoint(x: X, y: Y), to: NSPoint(x: x, y: Y), radius: rad)
        path.appendArc(from: NSPoint(x: x, y: Y), to: NSPoint(x: x, y: y), radius: rad)
        path.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: X, y: y), radius: rad)
        path.close()

        ctx.saveGState()
        ctx.setAlpha(bubbleAlpha)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: NSColor.black.withAlphaComponent(dark ? 0.45 : 0.16).cgColor)
        Palette.claudeFill(dark).setFill()
        path.fill()
        ctx.restoreGState()
        Palette.claudeBorder(dark).setStroke()
        path.lineWidth = 1
        path.stroke()

        let name = L10n.buddyName.uppercased() as NSString
        name.draw(at: NSPoint(x: x + padding.width, y: y + padding.height - 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: Palette.body, .kern: 0.9,
        ])
        (visibleText as NSString).draw(
            with: NSRect(x: x + padding.width, y: y + padding.height + headerHeight,
                         width: bubbleTextSize.width + 1, height: bubbleTextSize.height + 2),
            options: [.usesLineFragmentOrigin], attributes: textAttrs)
        ctx.restoreGState()
    }

    private func drawParticles() {
        for p in particles {
            let a = min(1, p.life / p.maxLife * 1.6)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: p.size, weight: .heavy),
                .foregroundColor: p.color.withAlphaComponent(a),
            ]
            if p.outlined {
                attrs[.strokeColor] = NSColor.white.withAlphaComponent(a * 0.9)
                attrs[.strokeWidth] = -3
            }
            (p.text as NSString).draw(at: NSPoint(x: p.x, y: p.y), withAttributes: attrs)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        dragMoved = false
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - dragStartMouse.x, dy = m.y - dragStartMouse.y
        if !dragMoved && abs(dx) + abs(dy) > 3 {
            dragMoved = true
            act = nil
            onDragStart?()
        }
        if dragMoved { window?.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if dragMoved {
            squishUntil = tick + 5
            onDropped?()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if bubbleShowing && bubbleRect.contains(p) && !crabRect.contains(p) {
            hideBubble()
        } else {
            pokeUntil = tick + 24
            jump(3)
            onPoke?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Static art (menu bar, settings, app icon)

    static func statusIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            let u: CGFloat = 1.25, ox: CGFloat = 0.25, oy: CGFloat = 1.75
            func fill(_ c: Int, _ r: Int, _ w: Int, _ h: Int) {
                NSRect(x: ox + CGFloat(c) * u, y: oy + CGFloat(r) * u, width: CGFloat(w) * u, height: CGFloat(h) * u).fill()
            }
            NSColor.black.setFill()
            fill(2, 0, 10, 8); fill(0, 4, 2, 2); fill(12, 4, 2, 2)
            for c in [3, 5, 8, 10] { fill(c, 8, 1, 2) }
            NSGraphicsContext.current?.compositingOperation = .clear
            fill(4, 2, 1, 2); fill(9, 2, 1, 2)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Crab drawn at `unit` points per grid cell, waving. Size is 14×10 units.
    static func crabImage(unit: CGFloat, happy: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 14 * unit, height: 10 * unit), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
            drawWavingCrab(at: .zero, unit: unit, happy: happy)
            return true
        }
    }

    static func drawWavingCrab(at origin: NSPoint, unit: CGFloat, happy: Bool) {
        var p = Pose()
        p.lArm = .up
        p.eyes = happy ? .happy : .open
        paint(p, at: origin, unit: unit)
    }
}
