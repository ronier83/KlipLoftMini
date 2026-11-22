import AppKit
import Carbon.HIToolbox

/// A single system-wide shortcut via Carbon's RegisterEventHotKey, which (unlike an
/// NSEvent global monitor) needs no Accessibility permission and swallows the keystroke.
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)? {
        get { GlobalHotKeyRegistry.shared[.openKlip] }
        set { GlobalHotKeyRegistry.shared[.openKlip] = newValue }
    }

    private init() {}

    func registerSaved() {
        let defaults = UserDefaults.standard
        register(
            keyCode: UInt32(defaults.integer(forKey: Prefs.hotKeyCode)),
            modifiers: UInt32(defaults.integer(forKey: Prefs.hotKeyModifiers))
        )
    }

    /// Returns `false` if the combo matches another of the app's shortcuts.
    @discardableResult
    func save(keyCode: UInt32, modifiers: UInt32, display: String) -> Bool {
        guard !GlobalHotKeyRegistry.shared.conflictsWithOtherSlot(
            slot: .openKlip,
            keyCode: keyCode,
            modifiers: modifiers
        ) else { return false }
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Prefs.hotKeyCode)
        defaults.set(Int(modifiers), forKey: Prefs.hotKeyModifiers)
        defaults.set(display, forKey: Prefs.hotKeyDisplay)
        register(keyCode: keyCode, modifiers: modifiers)
        return true
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        GlobalHotKeyRegistry.shared.register(slot: .openKlip, keyCode: keyCode, modifiers: modifiers)
    }

    func unregister() {
        GlobalHotKeyRegistry.shared.unregister(slot: .openKlip)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    static func displayString(for event: NSEvent) -> String {
        let flags = event.modifierFlags
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        let key: String = switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
        return symbols + key
    }
}
