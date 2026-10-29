import AppKit
import SwiftUI

/// Everything the notch can show. Sizes follow ISLAND_SPEC.md; later stages fill in the content.
enum NotchState { case compact, sleeping, hover, approval, done, chatThinking, chatAnswer, fileOver }

enum NotchStyle {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.65)
    /// Concave flare where the notch meets the top edge of the screen.
    static let shoulder: CGFloat = 8
    /// Wide enough for the biggest state plus its shoulders and spring overshoot.
    static let canvasWidth: CGFloat = 480
    static let canvasExtraHeight: CGFloat = 300

    static let title = Color.white
    static let secondary = Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.6)
    static let orange = Color(.sRGB, red: 1, green: 159 / 255, blue: 10 / 255)
    static let green = Color(.sRGB, red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let yellow = Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255)
    static let idle = Color(.sRGB, red: 72 / 255, green: 72 / 255, blue: 74 / 255)
    static let button = Color(.sRGB, red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let buttonRaised = Color(.sRGB, red: 44 / 255, green: 44 / 255, blue: 46 / 255)
}

final class NotchModel: ObservableObject {
    @Published var state: NotchState = .compact
    /// Real cutout size from the system (or a stand-in on screens without a notch).
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var title = L10n.buddyName
    @Published var subtitle = "Claude Code"

    var size: CGSize { Self.size(of: state, notchWidth: notchWidth, notchHeight: notchHeight) }
    var bottomRadius: CGFloat { Self.radius(of: state) }

    static func size(of s: NotchState, notchWidth n: CGFloat, notchHeight h: CGFloat) -> CGSize {
        switch s {
        // At rest the island hides inside the real cutout: shoulders included, it is exactly as wide.
        case .compact: return CGSize(width: n - 2 * NotchStyle.shoulder, height: h)
        case .sleeping: return CGSize(width: n + 2 * 26, height: h)
        case .hover, .fileOver: return CGSize(width: 360, height: h + 58)
        case .approval: return CGSize(width: 380, height: h + 110)
        case .done: return CGSize(width: 320, height: h + 52)
        case .chatThinking: return CGSize(width: 360, height: h + 56)
        case .chatAnswer: return CGSize(width: 400, height: h + 150)
        }
    }

    static func radius(of s: NotchState) -> CGFloat {
        switch s {
        case .compact, .sleeping: return 10
        case .hover, .fileOver, .chatThinking: return 26
        case .approval, .chatAnswer: return 30
        case .done: return 24
        }
    }
}

/// The notch outline: square top glued to the screen edge with small concave shoulders, rounded bottom.
/// Drawn centred at the top of its rect; width/height exclude the shoulders.
struct NotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var shoulder: CGFloat = NotchStyle.shoulder

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), bottomRadius) }
        set { width = newValue.first.first; height = newValue.first.second; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let l = rect.midX - width / 2, r = rect.midX + width / 2
        let top = rect.minY, bottom = rect.minY + height
        let s = min(shoulder, height / 2), br = min(bottomRadius, width / 2, height - s)
        var p = Path()
        p.move(to: CGPoint(x: l - s, y: top))
        p.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: l, y: top + s), radius: s)
        p.addArc(tangent1End: CGPoint(x: l, y: bottom), tangent2End: CGPoint(x: l + br, y: bottom), radius: br)
        p.addArc(tangent1End: CGPoint(x: r, y: bottom), tangent2End: CGPoint(x: r, y: bottom - br), radius: br)
        p.addArc(tangent1End: CGPoint(x: r, y: top), tangent2End: CGPoint(x: r + s, y: top), radius: s)
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let size = model.size
        let shape = NotchShape(width: size.width, height: size.height, bottomRadius: model.bottomRadius)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
    }

    @ViewBuilder private var content: some View {
        // The top band at cutout height stays empty: the camera lives there.
        switch model.state {
        case .hover:
            HoverContent(model: model)
                .padding(.top, model.notchHeight)
                .transition(.notchContent)
        default:
            EmptyView()
        }
    }
}

private struct HoverContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: BuddyView.crabImage(unit: 2))
                .interpolation(.none)
                .frame(width: 28, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(NotchStyle.title)
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundColor(NotchStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            CircleButton(symbol: "bubble.left.fill")
            CircleButton(symbol: "text.viewfinder")
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

/// 34 pt round dark button with an SF Symbol. Actions arrive in later stages.
private struct CircleButton: View {
    let symbol: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(NotchStyle.buttonRaised))
        }
        .buttonStyle(.plain)
    }
}

/// Content fades in from a blur slightly after the shape starts growing, and leaves quicker.
private struct Reveal: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .scaleEffect(shown ? 1 : 0.94)
    }
}

extension AnyTransition {
    static var notchContent: AnyTransition {
        let reveal = AnyTransition.modifier(active: Reveal(shown: false), identity: Reveal(shown: true))
        return .asymmetric(insertion: reveal.animation(.easeOut(duration: 0.3).delay(0.15)),
                           removal: reveal.animation(.easeIn(duration: 0.12)))
    }
}
