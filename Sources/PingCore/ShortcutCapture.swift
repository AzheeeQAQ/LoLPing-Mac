import Foundation

/// Records one physical chord, freezes it on the first release, and emits once
/// every participating key is up. No UI, event taps, or preference writes.
public final class ShortcutCapture {
    public private(set) var modifiers: Modifiers = []
    public private(set) var keys: Set<Int> = []
    public private(set) var candidate: TriggerChord?
    private var released = false
    public init() {}
    public func flagsChanged(_ flags: Modifiers) -> TriggerChord? {
        if !modifiers.subtracting(flags).isEmpty { released = true }
        modifiers = flags
        return update()
    }
    public func keyChanged(_ code: Int, isDown: Bool) -> TriggerChord? {
        guard TriggerChord.isRecordableKey(code) else { return nil }
        if isDown { keys.insert(code) }
        else { if keys.contains(code) { released = true }; keys.remove(code) }
        return update()
    }
    private func update() -> TriggerChord? {
        if !released, let chord = TriggerChord(modifiers: modifiers, keyCodes: keys) {
            candidate = chord
        }
        guard released && modifiers.isEmpty && keys.isEmpty else { return nil }
        let result = candidate; reset(); return result
    }
    public func reset() { modifiers = []; keys = []; candidate = nil; released = false }
}
