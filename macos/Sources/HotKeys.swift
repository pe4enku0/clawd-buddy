import AppKit
import Carbon.HIToolbox

/// A global shortcut: Carbon key code + Carbon modifier mask, plus how to show it.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let chatDefault = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥Space")
    static let screenDefault = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey),
                                      display: "⌥⇧Space")

    /// From a key press in the recorder; nil without ⌘/⌥/⌃ (a bare key would hijack typing).
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods: UInt32 = 0, symbols = ""
        if f.contains(.control) { mods |= UInt32(controlKey); symbols += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); symbols += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); symbols += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); symbols += "⌘" }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, display: symbols + key)
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

/// System-wide shortcuts via Carbon RegisterEventHotKey, which needs no Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()
    /// Set while the settings recorder listens, so pressing the old shortcut doesn't fire it.
    var paused = false
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Registers (or with nil, removes) shortcut `id`. Returns false if macOS refused it.
    @discardableResult
    func set(_ id: UInt32, _ key: Hotkey?, handler: @escaping () -> Void) -> Bool {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
        guard let key else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x434C_5744), id: id)  // "CLWD"
        guard RegisterEventHotKey(key.keyCode, key.modifiers, hid, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hid = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
            DispatchQueue.main.async {
                if !HotKeys.shared.paused { HotKeys.shared.handlers[hid.id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Settings-side "press the new shortcut" state. One recorder at a time.
final class HotkeyRecorder: ObservableObject {
    static let shared = HotkeyRecorder()
    @Published private(set) var recording: String?
    private var monitor: Any?
    private var onCapture: ((Hotkey) -> Void)?

    func start(_ id: String, onCapture: @escaping (Hotkey) -> Void) {
        stop()
        recording = id
        self.onCapture = onCapture
        HotKeys.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            if let key = Hotkey(event: e) { self.onCapture?(key); self.stop() } else { NSSound.beep() }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        onCapture = nil
        recording = nil
        HotKeys.shared.paused = false
    }
}
