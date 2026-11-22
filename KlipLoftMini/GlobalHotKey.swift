import os
import AppKit
import Carbon.HIToolbox

/// Dispatches Carbon global hot keys registered under the Klip signature (`KLIP`).
enum GlobalHotKeySlot: UInt32, CaseIterable {
    case openKlip = 1

    /// Where the slot's key code and Carbon modifiers are saved.
    var prefsKeys: (code: String, modifiers: String) {
        switch self {
        case .openKlip: (Prefs.hotKeyCode, Prefs.hotKeyModifiers)
        }
    }
}

/// Multiple `RegisterEventHotKey` bindings with one Carbon handler (reads `EventHotKeyID`).
final class GlobalHotKeyRegistry {
    static let shared = GlobalHotKeyRegistry()

    private struct Binding {
        var ref: EventHotKeyRef?
        var onPress: (() -> Void)?
    }

    private var bindings: [UInt32: Binding] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4B4C_4950 // 'KLIP'

    private init() {}

    subscript(slot: GlobalHotKeySlot) -> (() -> Void)? {
        get { bindings[slot.rawValue]?.onPress }
        set {
            var binding = bindings[slot.rawValue] ?? Binding()
            binding.onPress = newValue
            bindings[slot.rawValue] = binding
        }
    }

    /// True when `keyCode`+`modifiers` matches any other Klip global shortcut's saved combo.
    func conflictsWithOtherSlot(slot: GlobalHotKeySlot, keyCode: UInt32, modifiers: UInt32) -> Bool {
        let defaults = UserDefaults.standard
        return GlobalHotKeySlot.allCases.contains { other in
            guard other != slot else { return false }
            let keys = other.prefsKeys
            return UInt32(defaults.integer(forKey: keys.code)) == keyCode
                && UInt32(defaults.integer(forKey: keys.modifiers)) == modifiers
        }
    }

    func register(slot: GlobalHotKeySlot, keyCode: UInt32, modifiers: UInt32) {
        unregister(slot: slot)
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            EventLog.shortcuts.error("\(String(describing: slot), privacy: .public) NOT registered: key \(keyCode), modifiers \(modifiers), status \(status) (taken by another app?)")
            return
        }
        EventLog.shortcuts.notice("\(String(describing: slot), privacy: .public) registered: key \(keyCode), modifiers \(modifiers)")
        var binding = bindings[slot.rawValue] ?? Binding()
        binding.ref = ref
        bindings[slot.rawValue] = binding
    }

    /// macOS accepted the slot's shortcut (it fails when another app already owns the combo).
    func isRegistered(slot: GlobalHotKeySlot) -> Bool {
        bindings[slot.rawValue]?.ref != nil
    }

    func unregister(slot: GlobalHotKeySlot) {
        if let ref = bindings[slot.rawValue]?.ref {
            UnregisterEventHotKey(ref)
        }
        bindings[slot.rawValue]?.ref = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), globalHotKeyHandler, 1, &spec, nil, &handlerRef)
    }

    fileprivate func fire(id: UInt32) {
        EventLog.shortcuts.notice("\(GlobalHotKeySlot(rawValue: id).map { String(describing: $0) } ?? "slot \(id)", privacy: .public) pressed")
        bindings[id]?.onPress?()
    }
}

private nonisolated func globalHotKeyHandler(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let size = MemoryLayout<EventHotKeyID>.size
    let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        size,
        nil,
        &hotKeyID
    )
    guard err == noErr else { return noErr }
    MainActor.assumeIsolated {
        GlobalHotKeyRegistry.shared.fire(id: hotKeyID.id)
    }
    return noErr
}

