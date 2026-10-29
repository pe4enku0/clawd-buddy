import AppKit
import SwiftUI

// Chat in the notch: input, "thinking…", and the streamed answer with a follow-up field.

enum ChatPhase { case input, thinking, answer }

/// Space under the answer text in the answer card: header, gaps, input row and paddings.
let chatAnswerChrome: CGFloat = 92
let chatAnswerMaxExtra: CGFloat = 260

struct ChatInputContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 10) {
            CrabSprite(buddy: model.buddy, unit: 1.5)
                .frame(width: 22, height: 18)
            ChatInputRow(model: model, placeholder: L10n.ui(.chatPlaceholder))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct ChatThinkingContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .top) {
                CrabSprite(buddy: model.buddy, unit: 2, thinking: true)
                    .frame(width: 28, height: 22)
                    .padding(.top, 8)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Text("?")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundColor(NotchStyle.orange)
                        .offset(x: 10, y: -4 - CGFloat(sin(t * 2 * .pi)) * 2)
                }
            }
            .frame(width: 30, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.ui(.chatThinking))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(NotchStyle.title)
                Text(model.chatQuestion)
                    .font(.system(size: 12.5))
                    .foregroundColor(NotchStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

struct ChatAnswerContent: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CrabSprite(buddy: model.buddy, unit: 1.5)
                    .frame(width: 22, height: 16)
                Text(model.chatQuestion)
                    .font(.system(size: 12.5))
                    .foregroundColor(NotchStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if model.answerHovered && !model.chatAnswer.isEmpty {
                    CopyButton(model: model)
                }
            }
            .frame(height: 18)
            ScrollView(.vertical, showsIndicators: false) {
                AnswerText(text: model.chatAnswer, isError: model.chatError)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: AnswerHeightKey.self, value: g.size.height)
                    })
            }
            .onPreferenceChange(AnswerHeightKey.self) { h in
                if abs(h - model.chatAnswerHeight) > 0.5 {
                    withAnimation(NotchStyle.spring) { model.chatAnswerHeight = h }
                }
            }
            .contextMenu {
                Button(L10n.ui(.copy)) { model.copyAnswer() }
            }
            ChatInputRow(model: model, placeholder: L10n.ui(.chatMore))
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { model.answerHovered = $0 }
    }
}

private struct AnswerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CopyButton: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        Button(action: model.copyAnswer) {
            let copied = Date().timeIntervalSince(model.copiedAt) < 1.5
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(L10n.ui(copied ? .copied : .copy))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Capsule().fill(NotchStyle.buttonRaised))
        }
        .buttonStyle(.plain)
    }
}

/// Capsule text field + round orange send button.
struct ChatInputRow: View {
    @ObservedObject var model: NotchModel
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            ChatField(model: model, placeholder: placeholder)
                .frame(height: 20)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(NotchStyle.buttonRaised))
            Button(action: model.submitDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(NotchStyle.orange))
            }
            .buttonStyle(.plain)
        }
    }
}

/// AppKit text field: reliable focus in a non-activating panel, Enter sends, Esc closes.
struct ChatField: NSViewRepresentable {
    let model: NotchModel
    let placeholder: String

    func makeNSView(context: Context) -> ChatTextField {
        let f = ChatTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.textColor = .white
        f.cell?.lineBreakMode = .byTruncatingHead
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        model.chatField = f
        return f
    }

    func updateNSView(_ f: ChatTextField, context: Context) {
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.45),
            .font: NSFont.systemFont(ofSize: 13),
        ])
        context.coordinator.model = model
        model.chatField = f
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: NotchModel
        init(model: NotchModel) { self.model = model }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): model.submitDraft(); return true
            case #selector(NSResponder.cancelOperation(_:)): model.onChatClose?(); return true
            default: return false
            }
        }
    }
}

final class ChatTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The card appears with the window already key: take the keyboard straight away.
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window, w.isKeyWindow else { return }
            w.makeFirstResponder(self)
        }
    }
}

/// Answer text: 14 pt, `inline code` and ``` blocks in orange SF Mono.
struct AnswerText: View {
    let text: String
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.code {
                    Text(block.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(NotchStyle.orange)
                } else {
                    Text(Self.inline(block.text))
                        .font(.system(size: 14))
                        .foregroundColor(isError ? NotchStyle.yellow : .white)
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Splits on ``` fences; an unclosed fence (still streaming) runs to the end.
    static func blocks(_ s: String) -> [(code: Bool, text: String)] {
        var out: [(Bool, String)] = []
        for (i, part) in s.components(separatedBy: "```").enumerated() {
            var t = part
            if i % 2 == 1, let nl = t.firstIndex(of: "\n"), !t[..<nl].contains(" ") {
                t = String(t[t.index(after: nl)...])  // drop the language tag
            }
            t = t.trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append((i % 2 == 1, t)) }
        }
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var a = try? AttributedString(markdown: s, options: opts) else { return AttributedString(s) }
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 13, design: .monospaced)
            a[run.range].foregroundColor = NotchStyle.orange
        }
        return a
    }
}
