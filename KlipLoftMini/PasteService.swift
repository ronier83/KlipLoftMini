import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Writes clips to the pasteboard and simulates ⌘V into the frontmost app.
/// Simulating keystrokes needs Accessibility access, which is why Klip isn't sandboxed.
enum PasteService {
    // Nonisolated: `AXIsProcessTrusted` is a thread-safe C call, and the window switcher's
    // off-main gather checks it from a background queue.
    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Several clips at once: text is joined line by line so it pastes as one block;
    /// files, images and mixed selections go on the pasteboard as separate items.
    static func write(_ items: [ClipItem], plainText: Bool) {
        guard items.count > 1 else {
            if let item = items.first { write(item, plainText: plainText) }
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if items.allSatisfy({ $0.kind.isTextual }) {
            pasteboard.setString(items.compactMap(\.text).joined(separator: "\n"), forType: .string)
            return
        }
        var objects: [NSPasteboardWriting] = []
        for item in items {
            switch item.kind {
            case .image:
                if let data = item.imagePayload, let image = NSImage(data: data) { objects.append(image) }
            case .file:
                objects.append(contentsOf: item.fileURLs as [NSURL])
            case .text, .link, .color:
                if let text = item.text { objects.append(text as NSString) }
            }
        }
        pasteboard.writeObjects(objects)
    }

    static func write(_ item: ClipItem, plainText: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .image:
            if let data = item.imagePayload, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .file:
            pasteboard.writeObjects(item.fileURLs as [NSURL])
            // Like a Finder copy: the names as plain text, one per line, so a text field gets them.
            pasteboard.setString(item.fileURLs.map(\.lastPathComponent).joined(separator: "\r"), forType: .string)
        case .text, .link, .color:
            guard let text = item.text else { return }
            if !plainText, let rtf = item.rtfData {
                pasteboard.setData(trimmedRTF(rtf, matching: text), forType: .rtf)
            }
            pasteboard.setString(text, forType: .string)
        }
    }

    /// A Word selection that runs to the end of a paragraph carries the paragraph mark in its RTF
    /// but not in its plain text, so the paste gained a hard return the clip doesn't show.
    /// Drops trailing line breaks the RTF has beyond the clip's own text.
    static func trimmedRTF(_ rtf: Data, matching text: String) -> Data {
        var attributes: NSDictionary?
        guard let rich = try? NSMutableAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: &attributes) else { return rtf }
        let wanted = text.reversed().prefix(while: \.isNewline).count
        let trailing = rich.string.reversed().prefix(while: \.isNewline)
        guard trailing.count > wanted else { return rtf }
        let cut = trailing.prefix(trailing.count - wanted).reduce(0) { $0 + $1.utf16.count }
        rich.deleteCharacters(in: NSRange(location: rich.length - cut, length: cut))
        var docAttributes = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        docAttributes[.documentType] = NSAttributedString.DocumentType.rtf
        return (try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: docAttributes)) ?? rtf
    }

    static func sendPasteKeystroke() {
        guard isTrusted else {
            requestAccess()
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = commandVKey()
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// The key that types ⌘V on the user's layout. On Dvorak that's the key in QWERTY's "." spot,
    /// so the fixed QWERTY V key sent ⌘. and nothing pasted. "Dvorak – QWERTY ⌘" and non-Latin
    /// layouts (whose shortcuts follow the last Latin one) keep the QWERTY position.
    static func commandVKey() -> CGKeyCode {
        let qwertyV = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return qwertyV }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let cmdState = UInt32((cmdKey >> 8) & 0xFF)
        func character(_ key: CGKeyCode) -> String? {
            data.withUnsafeBytes { raw -> String? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDown), cmdState,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                return status == noErr ? String(utf16CodeUnits: chars, count: length).lowercased() : nil
            }
        }
        if character(qwertyV) == "v" { return qwertyV }
        return (0..<128).map(CGKeyCode.init).first { character($0) == "v" } ?? qwertyV
    }
}
