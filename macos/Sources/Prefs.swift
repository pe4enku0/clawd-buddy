import AppKit
import Combine

enum BubbleStyle: String, CaseIterable { case pixel, claude }

/// Where the buddy lives: its own corner window, or inside the MacBook notch.
enum BuddyMode: String, CaseIterable { case corner, notch }

enum BuddySize: String, CaseIterable {
    case small, medium, large
    // Multiples of 1/3 keep the 6pt sprite grid on whole Retina pixels.
    var scale: CGFloat {
        switch self {
        case .small: return 2.0 / 3
        case .medium: return 1
        case .large: return 4.0 / 3
        }
    }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var lang: Lang { didSet { d.set(lang.rawValue, forKey: "lang"); L10n.lang = lang } }
    @Published var bubbleStyle: BubbleStyle { didSet { d.set(bubbleStyle.rawValue, forKey: "bubbleStyle") } }
    @Published var size: BuddySize { didSet { d.set(size.rawValue, forKey: "size") } }
    @Published var chattiness: Double { didSet { d.set(chattiness, forKey: "chattiness") } }
    @Published var idleChatter: Bool { didSet { d.set(idleChatter, forKey: "idleChatter") } }
    @Published var followMouse: Bool { didSet { d.set(followMouse, forKey: "followMouse") } }
    @Published var hideWhenSleeping: Bool { didSet { d.set(hideWhenSleeping, forKey: "hideWhenSleeping") } }
    @Published var mode: BuddyMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var hideInFullscreen: Bool { didSet { d.set(hideInFullscreen, forKey: "hideInFullscreen") } }

    /// Top-right corner of the buddy window, so it stays put when the size changes.
    var anchor: NSPoint? {
        get {
            guard d.object(forKey: "anchorX") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
        }
        set {
            if let p = newValue { d.set(p.x, forKey: "anchorX"); d.set(p.y, forKey: "anchorY") }
            else { d.removeObject(forKey: "anchorX"); d.removeObject(forKey: "anchorY") }
        }
    }

    private init() {
        lang = Lang(rawValue: d.string(forKey: "lang") ?? "") ?? .en
        bubbleStyle = BubbleStyle(rawValue: d.string(forKey: "bubbleStyle") ?? "") ?? .pixel
        size = BuddySize(rawValue: d.string(forKey: "size") ?? "") ?? .medium
        chattiness = d.object(forKey: "chattiness") as? Double ?? 0.3
        idleChatter = d.object(forKey: "idleChatter") as? Bool ?? true
        followMouse = d.object(forKey: "followMouse") as? Bool ?? true
        hideWhenSleeping = d.bool(forKey: "hideWhenSleeping")
        mode = BuddyMode(rawValue: d.string(forKey: "mode") ?? "") ?? .corner
        hideInFullscreen = d.object(forKey: "hideInFullscreen") as? Bool ?? true
        L10n.lang = lang
    }

    @Published private(set) var hooksInstalled = false

    func refreshHooksStatus() {
        let path = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        let s = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let installed = s.contains("ClawdBuddy\\\" hook") || s.contains("ClawdBuddy hook")
        if installed != hooksInstalled { hooksInstalled = installed }
    }
}
