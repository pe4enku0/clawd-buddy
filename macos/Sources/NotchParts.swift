import AppKit
import SwiftUI

// Small animated pieces of the notch: the live crab, wing icons, outline and confetti.

/// The live crab from `BuddyView`, redrawn at notch size.
struct CrabSprite: NSViewRepresentable {
    let buddy: BuddyView
    let unit: CGFloat

    func makeNSView(context: Context) -> NotchCrabView { NotchCrabView(buddy: buddy, unit: unit) }
    func updateNSView(_ view: NotchCrabView, context: Context) { view.unit = unit }
}

final class NotchCrabView: NSView {
    private weak var buddy: BuddyView?
    var unit: CGFloat
    private var timer: Timer?

    init(buddy: BuddyView, unit: CGFloat) {
        self.buddy = buddy
        self.unit = unit
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.frameTick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func frameTick() {
        guard let buddy, let window else { return }
        // Map the cursor into the corner buddy's coordinates so the eyes follow it here too.
        let r = window.convertToScreen(convert(bounds, to: nil))
        let m = NSEvent.mouseLocation, k = BuddyView.unit / unit, a = buddy.eyeAnchor
        buddy.mouse = NSPoint(x: a.x + (m.x - r.midX) * k, y: a.y - (m.y - r.midY) * k)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let buddy, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(false)
        let w = CGFloat(BuddyView.gridW) * unit, h = CGFloat(BuddyView.gridH) * unit
        // Whole points keep the pixel grid crisp.
        let origin = NSPoint(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded())
        buddy.paintCrab(at: origin, unit: unit)
    }
}

/// Wide pill button: dark for secondary actions, orange with black text for the main one.
struct CapsuleButton: View {
    let title: String
    let fill: Color
    let text: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(text)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Time left before the card folds away; clicking it hands the question back to the terminal.
struct CountdownRing: View {
    let since: Date
    let duration: TimeInterval
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let left = max(0, 1 - tl.date.timeIntervalSince(since) / duration)
                ZStack {
                    Circle().stroke(NotchStyle.buttonRaised, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: left)
                        .stroke(NotchStyle.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchStyle.secondary)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
    }
}

/// easeOutBack from 0 to 1 over 0.35 s: a little overshoot, like a pop.
func popScale(_ t: TimeInterval, delay: TimeInterval = 0) -> CGFloat {
    let x = min(max((t - delay) / 0.35, 0), 1) - 1
    let c1 = 1.70158, c3 = c1 + 1
    return CGFloat(1 + c3 * x * x * x + c1 * x * x)
}

/// Pops its content in (scale 0 → 1 with overshoot) whenever `since` changes.
struct PopIn<Content: View>: View {
    let since: Date
    var delay: TimeInterval = 0.15
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelineView(.animation) { tl in
            content().scaleEffect(popScale(tl.date.timeIntervalSince(since), delay: delay))
        }
    }
}

/// The right wing: what Claude is doing right now.
struct WingIcon: View {
    let activity: NotchActivity
    let since: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSince(since)
            icon(t).scaleEffect(activity == .sleeping ? 1 : popScale(t))
        }
    }

    @ViewBuilder private func icon(_ t: TimeInterval) -> some View {
        switch activity {
        case .writing:
            symbol("pencil").rotationEffect(.degrees(sin(t * 5) * 10))
        case .running:
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(NotchStyle.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(t * 400))
        case .reading: symbol("doc.text")
        case .searching: symbol("magnifyingglass")
        case .web: symbol("globe")
        case .thinking: symbol("ellipsis").opacity(0.55 + 0.45 * sin(t * 4))
        case .waiting: symbol("hand.raised.fill")
        case .oops:
            Circle().fill(NotchStyle.yellow).frame(width: 14, height: 14)
                .overlay(Text("!").font(.system(size: 10, weight: .heavy)).foregroundColor(.black))
        case .sleeping:
            ZStack {
                ForEach(0..<2) { i in
                    let phase = (t + Double(i) * 1.1).truncatingRemainder(dividingBy: 2.2) / 2.2
                    Text("z")
                        .font(.system(size: 9 + CGFloat(i) * 2, weight: .semibold, design: .rounded))
                        .foregroundColor(NotchStyle.secondary)
                        .opacity(sin(.pi * phase))
                        .offset(x: CGFloat(i * 5) - 2 + CGFloat(phase) * 3, y: 4 - CGFloat(phase) * 10)
                }
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(NotchStyle.orange)
    }
}

/// 1.5 pt line along the sides and bottom (the top is the screen edge).
/// The root view clips to the island, so a 3 pt stroke shows 1.5 pt inside it.
struct NotchOutlineView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        if model.outline != .none || model.flash != nil {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let now = tl.date
                let size = model.size
                let edge = NotchShape(width: size.width, height: size.height, bottomRadius: model.bottomRadius, open: true)
                let w = NotchStyle.outlineWidth * 2
                ZStack {
                    switch model.outline {
                    case .comet:
                        // Keep the angle small: the renderer works in single precision.
                        let angle = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2 * 360
                        edge.stroke(AngularGradient(gradient: Self.comet, center: .center, angle: .degrees(angle)),
                                    style: StrokeStyle(lineWidth: w, lineCap: .round))
                    case .breathe:
                        let phase = now.timeIntervalSinceReferenceDate * 2 * .pi / 1.3
                        edge.stroke(NotchStyle.orange, lineWidth: w).opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(phase)))
                    case .none:
                        EmptyView()
                    }
                    if let f = model.flash {
                        edge.stroke(f.color, lineWidth: w).opacity(Self.flashAlpha(now.timeIntervalSince(f.start), f.duration))
                    }
                }
                // Shade on the GPU; a conic gradient redrawn by CoreGraphics every frame costs ~20% CPU.
                .drawingGroup()
            }
        }
    }

    /// Two comets half a turn apart: there's no line along the top, so one is always on a visible edge.
    private static let comet = Gradient(stops: [0, 0.5].flatMap { o -> [Gradient.Stop] in [
        .init(color: .clear, location: o),
        .init(color: .clear, location: o + 0.2),
        .init(color: NotchStyle.orange.opacity(0.9), location: o + 0.42),
        .init(color: NotchStyle.yellow, location: o + 0.49),
        .init(color: .clear, location: o + 0.5),
    ] })

    /// Quick rise, slow fade.
    private static func flashAlpha(_ t: TimeInterval, _ d: TimeInterval) -> Double {
        if t < 0 || t > d { return 0 }
        return t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / (d - 0.15)
    }
}

/// A small burst of confetti from the centre that falls and fades in ~1.6 s.
struct Confetti: View {
    let start: Date
    private static let life: TimeInterval = 1.6

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSince(start)
                guard t >= 0, t < Self.life else { return }
                let alpha = 1 - t / Self.life
                for i in 0..<16 {
                    let vx = (Self.noise(i, 0) - 0.5) * 120, vy = -70 - Self.noise(i, 1) * 70
                    let x = size.width / 2 + vx * t, y = size.height / 2 + vy * t + 150 * t * t
                    let color = Palette.confetti[i % Palette.confetti.count]
                    let s = 3 + Self.noise(i, 2) * 2
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(nsColor: color).opacity(alpha)))
                }
            }
        }
    }

    /// Stable pseudo-random 0..<1 per particle, so every frame agrees on the same burst.
    private static func noise(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i * 7 + k * 131) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }
}
