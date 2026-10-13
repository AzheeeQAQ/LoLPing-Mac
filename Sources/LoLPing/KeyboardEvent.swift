import AppKit
import PingCore

enum KeyboardEvent {
    static func specialModifier(_ code: Int) -> Modifiers? {
        code == 57 ? .capsLock : (code == 63 ? .function : nil)
    }
    static func standardModifiers(_ flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
    // Use physical key state: Caps Lock's latched flag and the implicit Fn bit
    // on arrows/F keys must not be mistaken for keys the user is holding.
    static func specialKeysDown() -> Modifiers {
        var result: Modifiers = []
        if CGEventSource.keyState(.combinedSessionState, key: 63) { result.insert(.function) }
        if CGEventSource.keyState(.combinedSessionState, key: 57) { result.insert(.capsLock) }
        return result
    }
    static func keyChange(_ event: NSEvent) -> (key: Int, down: Bool)? {
        if event.type == .keyDown || event.type == .keyUp {
            let key = Int(event.keyCode)
            return TriggerChord.isRecordableKey(key) ? (key, event.type == .keyDown) : nil
        }
        if event.type == .systemDefined, event.subtype.rawValue == 8 {
            let code = (event.data1 >> 16) & 0xffff, state = (event.data1 >> 8) & 0xff
            if code <= 255 && (state == 10 || state == 11) { return (65536+code, state == 10) }
        }
        return nil
    }
}
