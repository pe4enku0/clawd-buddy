import AppKit
import SwiftUI

/// Everything the notch can show. Sizes follow ISLAND_SPEC.md; later stages fill in the rest.
enum NotchState {
    case compact            // at rest: hidden inside the real cutout
    case wings              // Claude is busy: crab on the left, activity on the right
    case sleeping
    case hover, approval, done, chatInput, chatThinking, chatAnswer, fileOver
}

/// What the right wing shows.
enum NotchActivity { case writing, running, reading, searching, web, thinking, waiting, oops, sleeping }

/// Steady outline along the sides and bottom.
enum NotchOutline { case none, comet, breathe }

/// One-off outline flash (done, tool error).
struct NotchFlash: Equatable {
    let color: Color
    let start: Date
    let duration: TimeInterval
}

enum NotchStyle {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.65)
    /// Concave flare where the notch meets the top edge of the screen.
    static let shoulder: CGFloat = 8
    /// Wide enough for the biggest state plus its shoulders and spring overshoot.
    static let canvasWidth: CGFloat = 480
    static let canvasExtraHeight: CGFloat = 300
    static let outlineWidth: CGFloat = 1.5

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
    /// The corner buddy keeps all the animation state; the notch just draws it smaller.
    let buddy: BuddyView

    @Published var state: NotchState = .compact
    @Published var activity: NotchActivity = .thinking
    @Published var activitySince = Date()
    @Published var outline: NotchOutline = .none
    @Published var flash: NotchFlash?
    /// Real cutout size from the system (or a stand-in on screens without a notch).
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var title = L10n.buddyName
    @Published var subtitle = ""
    @Published var doneStats = ""
    @Published var doneAt = Date.distantPast
    @Published var approvalTitle = ""
    @Published var approvalDetail = ""
    @Published var approvalSince = Date.distantPast
    /// Lines the detail takes (1...CommandLabel.maxLines); false when it doesn't fit, and then
    /// Allow is off: you only approve what you can read in full.
    @Published var approvalLines = 1
    @Published var approvalFits = true
    /// Buttons on the approval card; the controller decides what a click may do.
    var onApprovalAnswer: ((ApprovalDecision) -> Void)?

    @Published var chatQuestion = ""
    @Published var chatAnswer = ""
    @Published var chatError = false
    /// Measured height of the answer text; the card grows with it up to a limit.
    @Published var chatAnswerHeight: CGFloat = 0
    @Published var answerHovered = false
    @Published var copiedAt = Date.distantPast
    /// The next question goes out with a screenshot (the button left of the field).
    @Published var chatAttachScreen = false
    @Published var chatLookingAtScreen = false
    /// No Screen Recording: waiting for a ⌘⌃⇧4 picture on the clipboard.
    @Published var chatAwaitingClip = false
    var onDescribeScreen: (() -> Void)?
    weak var chatField: NSTextField?
    var onChatSubmit: ((String) -> Void)?
    var onChatClose: (() -> Void)?
    var onOpenChat: (() -> Void)?
    /// Warning above the answer, e.g. a big file read only in part.
    @Published var chatNote = ""
    /// Name and size of the file being dragged over the notch, and whether we can read it.
    @Published var dragLabel = ""
    @Published var dragSupported = true

    func submitDraft() {
        guard let f = chatField else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        f.stringValue = ""
        onChatSubmit?(text)
    }

    func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chatAnswer, forType: .string)
        copiedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copiedAt = .distantPast }
    }

    init(buddy: BuddyView) { self.buddy = buddy }

    var size: CGSize {
        if state == .approval {
            // Paddings, title row, gaps and buttons, plus the detail lines and the "too long" note.
            let note = approvalFits ? 0 : 8 + CommandLabel.lineHeight
            return CGSize(width: 380, height: notchHeight + 104 + CGFloat(approvalLines) * CommandLabel.lineHeight + note)
        }
        if state == .chatAnswer {
            return CGSize(width: 400, height: notchHeight + min(chatAnswerMaxExtra, chatAnswerChrome + max(chatAnswerHeight, 20)))
        }
        return Self.size(of: state, notchWidth: notchWidth, notchHeight: notchHeight)
    }
    var bottomRadius: CGFloat { Self.radius(of: state) }

    static func size(of s: NotchState, notchWidth n: CGFloat, notchHeight h: CGFloat) -> CGSize {
        switch s {
        // At rest the island hides inside the real cutout: shoulders included, it is exactly as wide.
        case .compact: return CGSize(width: n - 2 * NotchStyle.shoulder, height: h)
        case .wings: return CGSize(width: n + 2 * 34, height: h)
        case .sleeping: return CGSize(width: n + 2 * 26, height: h)
        case .hover, .fileOver: return CGSize(width: 360, height: h + 58)
        case .approval: return CGSize(width: 380, height: h + 110)
        case .done: return CGSize(width: 320, height: h + 52)
        case .chatInput: return CGSize(width: 400, height: h + 58)
        case .chatThinking: return CGSize(width: 360, height: h + 56)
        case .chatAnswer: return CGSize(width: 400, height: h + 150)
        }
    }

    static func radius(of s: NotchState) -> CGFloat {
        switch s {
        case .compact, .wings, .sleeping: return 10
        case .hover, .fileOver, .chatThinking: return 26
        case .approval, .chatAnswer, .chatInput: return 30
        case .done: return 24
        }
    }
}

/// The notch outline: square top glued to the screen edge with small concave shoulders, rounded bottom.
/// Drawn centred at the top of its rect; width/height exclude the shoulders.
/// `open` leaves out the top edge, for the outline stroke.
struct NotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var shoulder: CGFloat = NotchStyle.shoulder
    var open = false

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
        if !open { p.closeSubpath() }
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
            NotchOutlineView(model: model)
                .frame(width: size.width, height: size.height, alignment: .top)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
    }

    @ViewBuilder private var content: some View {
        // Compact content lives only in the wings; expanded content sits below the camera band.
        switch model.state {
        case .wings, .sleeping:
            WingsContent(model: model).transition(.notchContent)
        case .hover:
            HoverContent(model: model).padding(.top, model.notchHeight).transition(.notchContent)
        case .done:
            DoneContent(model: model).padding(.top, model.notchHeight).transition(.notchContent)
        case .approval:
            ApprovalContent(model: model).padding(.top, model.notchHeight).transition(.notchContent)
        case .chatInput:
            ChatInputContent(model: model).padding(.top, model.notchHeight).transition(.notchContent)
        case .chatThinking:
            ChatThinkingContent(model: model).padding(.top, model.notchHeight).transition(.notchContent)
        case .chatAnswer:
            ChatAnswerContent(model: model).padding(.top, model.notchHeight).transition(.notchContent)
        case .fileOver:
            FileOverContent(model: model).padding(.top, model.notchHeight).transition(.notchContent)
        default:
            EmptyView()
        }
    }
}

private struct WingsContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let wing = (model.size.width - model.notchWidth) / 2
        HStack(spacing: 0) {
            CrabSprite(buddy: model.buddy, unit: 1.5)
                .frame(width: wing, height: model.notchHeight)
            Spacer(minLength: 0)
            WingIcon(activity: model.activity, since: model.activitySince)
                .frame(width: wing, height: model.notchHeight)
        }
    }
}

private struct HoverContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 12) {
            CrabSprite(buddy: model.buddy, unit: 2)
                .frame(width: 28, height: 26)
            TitleBlock(title: model.title, subtitle: model.subtitle)
            Spacer(minLength: 8)
            CircleButton(symbol: "bubble.left.fill") { model.onOpenChat?() }
            CircleButton(symbol: "text.viewfinder") { model.onDescribeScreen?() }
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

private struct DoneContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 12) {
            PopIn(since: model.doneAt) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black, NotchStyle.green)
                    .font(.system(size: 26))
            }
            TitleBlock(title: L10n.ui(.done), subtitle: model.doneStats)
            Spacer(minLength: 8)
            CrabSprite(buddy: model.buddy, unit: 2)
                .frame(width: 28, height: 30)
                .overlay(Confetti(start: model.doneAt).frame(width: 110, height: 70).allowsHitTesting(false))
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

private struct ApprovalContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CrabSprite(buddy: model.buddy, unit: 2)
                    .frame(width: 28, height: 26)
                Text(model.approvalTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(NotchStyle.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                CountdownRing(since: model.approvalSince, duration: ApprovalChannel.cardSeconds) {
                    model.onApprovalAnswer?(.terminal)
                }
                .help(L10n.ui(.answerInTerminal))
            }
            .frame(height: 28)
            CommandLabel(text: model.approvalDetail)
                .frame(width: CommandLabel.width,
                       height: CGFloat(min(model.approvalLines, CommandLabel.maxLines)) * CommandLabel.lineHeight,
                       alignment: .topLeading)
            if !model.approvalFits {
                Label(L10n.ui(.approvalTooLong), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(NotchStyle.yellow)
                    .frame(height: CommandLabel.lineHeight)
            }
            HStack(spacing: 10) {
                CapsuleButton(title: L10n.ui(.deny), fill: NotchStyle.buttonRaised, text: .white) {
                    model.onApprovalAnswer?(.deny)
                }
                CapsuleButton(title: L10n.ui(.allow), fill: NotchStyle.orange, text: .black, enabled: model.approvalFits) {
                    model.onApprovalAnswer?(.allow)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct FileOverContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 12) {
            CrabSprite(buddy: model.buddy, unit: 2, pose: .waving)
                .frame(width: 28, height: 26)
            TitleBlock(title: L10n.ui(model.dragSupported ? .fileDropTitle : .fileUnsupported), subtitle: model.dragLabel)
            Spacer(minLength: 8)
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let bob = sin(tl.date.timeIntervalSinceReferenceDate * 4) * 2
                Image(systemName: model.dragSupported ? "arrow.down" : "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(model.dragSupported ? NotchStyle.orange : NotchStyle.secondary)
                    .offset(y: model.dragSupported ? CGFloat(bob) : 0)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(NotchStyle.buttonRaised))
            }
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

private struct TitleBlock: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(NotchStyle.title)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundColor(NotchStyle.secondary)
                .lineLimit(1)
        }
    }
}

/// 34 pt round dark button with an SF Symbol.
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
