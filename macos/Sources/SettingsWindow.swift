import AppKit
import SwiftUI

/// Claude-flavoured palette: ivory paper, warm greys, clay accent. Adapts to dark mode.
private enum Claude {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let background = dyn(0xF5F4EE, 0x262624)
    static let card = dyn(0xFFFFFF, 0x30302E)
    static let border = dyn(0xE6E3DA, 0x3E3D39)
    static let track = dyn(0xEDEBE3, 0x1F1E1D)
    static let text = dyn(0x141413, 0xF5F4EF)
    static let secondary = dyn(0x73716B, 0xA6A39A)
    static let accent = Color(nsColor: Palette.body)
    static let ok = dyn(0x5E9A5A, 0x7FB77E)

    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

final class SettingsWindowController: NSWindowController {
    convenience init(prefs: Prefs, onDemo: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Claude.background)
        let hosting = NSHostingView(rootView: SettingsView(prefs: prefs, onDemo: onDemo))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
        self.init(window: window)
    }

    func present() {
        Prefs.shared.refreshHooksStatus()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    let onDemo: () -> Void
    private var hooksOn: Bool { prefs.hooksInstalled }
    /// The version comes from Info.plist so a bump is one edit, not three.
    private var footerText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return short.isEmpty ? L10n.ui(.footer) : "\(L10n.ui(.footer)) · v\(short)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            section(L10n.ui(.appearance)) {
                row(L10n.ui(.language)) {
                    Segmented(selection: $prefs.lang, options: [(.en, "English"), (.ru, "Русский")])
                }
                Divider().overlay(Claude.border)
                row(L10n.ui(.bubbleStyle)) {
                    Segmented(selection: $prefs.bubbleStyle,
                              options: [(.pixel, L10n.ui(.stylePixel)), (.claude, L10n.ui(.styleClaude))])
                }
                Divider().overlay(Claude.border)
                row(L10n.ui(.size)) {
                    Segmented(selection: $prefs.size, options: [
                        (.small, L10n.ui(.sizeSmall)), (.medium, L10n.ui(.sizeMedium)), (.large, L10n.ui(.sizeLarge)),
                    ])
                }
            }

            section(L10n.ui(.behavior)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.ui(.chattiness)).foregroundColor(Claude.text)
                        Spacer()
                        Text("\(Int(prefs.chattiness * 100))%").monospacedDigit().foregroundColor(Claude.secondary)
                    }
                    Slider(value: $prefs.chattiness, in: 0...1).tint(Claude.accent)
                    Text(L10n.ui(.chattinessHint)).font(.caption).foregroundColor(Claude.secondary)
                }
                Divider().overlay(Claude.border)
                toggle(L10n.ui(.idleChatter), L10n.ui(.idleChatterHint), $prefs.idleChatter)
                Divider().overlay(Claude.border)
                toggle(L10n.ui(.followMouse), L10n.ui(.followMouseHint), $prefs.followMouse)
                Divider().overlay(Claude.border)
                toggle(L10n.ui(.hideWhenSleeping), L10n.ui(.hideWhenSleepingHint), $prefs.hideWhenSleeping)
            }

            section(L10n.ui(.claudeCode)) {
                HStack(spacing: 10) {
                    Circle().fill(hooksOn ? Claude.ok : Claude.accent).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hooksOn ? L10n.ui(.hooksOn) : L10n.ui(.hooksOff)).foregroundColor(Claude.text)
                        if !hooksOn {
                            Text(L10n.ui(.hooksHint)).font(.caption).foregroundColor(Claude.secondary)
                        }
                    }
                    Spacer()
                    Button(action: onDemo) { Text(L10n.ui(.playDemo)) }.buttonStyle(AccentButton())
                }
            }

            Text(footerText).font(.caption).foregroundColor(Claude.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 460)
        .background(Claude.background)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: BuddyView.crabImage(unit: 4, happy: true))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Claude.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Claude.border))
            VStack(alignment: .leading, spacing: 4) {
                Text("Clawd Buddy").font(Claude.serif(28)).foregroundColor(Claude.text)
                Text(L10n.ui(.tagline)).font(.callout).foregroundColor(Claude.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Claude.serif(15)).foregroundColor(Claude.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Claude.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Claude.border))
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            Text(title).foregroundColor(Claude.text)
            Spacer()
            control()
        }
    }

    private func toggle(_ title: String, _ hint: String, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(Claude.text)
                Text(hint).font(.caption).foregroundColor(Claude.secondary)
            }
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).tint(Claude.accent).labelsHidden()
        }
    }
}

/// Pill-shaped segmented control in Claude's style.
private struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Claude.text : Claude.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selected ? Claude.card : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1.5, y: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = value } }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Claude.track))
    }
}

private struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Claude.accent.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}
