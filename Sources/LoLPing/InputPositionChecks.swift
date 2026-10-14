import AppKit
import PingCore

/// Unposted keyboard fixtures exercise the real shortcut router. Keyboard
/// events need not carry a usable mouse-event location.
enum InputPositionChecks {
    static func receiveFixture(endpoint: String) -> Int32 {
        let client = RelayClient(defaults: nil)
        client.serverAddress = endpoint
        var delivered = 0, received: CGPoint?, failure: String?
        client.onPositionedPing = { _, _, point in delivered += 1; received = point }
        client.onEmote = { _, _ in delivered += 1 }
        client.onFailure = { failure = $0 }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        defer { client.disconnect(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        client.createRoom()
        wait { client.positionWarning?.contains("信号") == true }
        guard failure == nil, client.positionWarning?.contains("信号") == true, delivered == 0, client.state == .connected else {
            print("FAIL missing ping position must warn without rendering or leaving the room"); return 1
        }
        client.sendPing(.generic, position: CGPoint(x: 0.1, y: 0.2))
        wait { client.positionWarning?.contains("表情") == true }
        guard failure == nil, client.positionWarning?.contains("表情") == true, delivered == 0 else {
            print("FAIL missing image position must warn without rendering"); return 1
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        client.sendPing(.assist, position: CGPoint(x: 0.1, y: 0.2))
        wait { delivered == 1 }
        guard failure == nil, delivered == 1, received == CGPoint(x: 0.23, y: 0.71), client.positionWarning == nil else {
            print("FAIL valid sender position must resume delivery and clear the warning"); return 1
        }
        print("PASS production receiver: coordinate-free ping/image packets never render; valid sender coordinates restore delivery without changing rooms")
        return 0
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        var failures = 0
        let chords = [TriggerChord.controlOptionCommand,
                      TriggerChord(modifiers: [.shift, .command], keyCode: 49)!,
                      TriggerChord(modifiers: [], keyCode: 0)!]
        for chord in chords {
            let input = GlobalInput(mouseButtonsDown: { false }, specialKeysDown: { [] })
            input.configure(chord: chord)
            let pointer = NSEvent.mouseLocation
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            event.location = CGPoint(x: 1_000_000, y: 1_000_000)
            var flags: CGEventFlags = []
            if chord.modifiers.contains(.control) { flags.insert(.maskControl) }
            if chord.modifiers.contains(.option) { flags.insert(.maskAlternate) }
            if chord.modifiers.contains(.command) { flags.insert(.maskCommand) }
            if chord.modifiers.contains(.shift) { flags.insert(.maskShift) }
            event.flags = flags
            if !flags.isEmpty { _ = input.process(.flagsChanged, event) }
            for key in chord.keyCodes.sorted() {
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
                _ = input.process(.keyDown, event)
            }
            if input.machine.phase != .arming || hypot(input.machine.anchor.x-pointer.x, input.machine.anchor.y-pointer.y) > 2 {
                failures += 1
                print("FAIL shortcut anchor must use the live pointer, not the keyboard event's location")
            }
            input.stop()
        }
        for frame in NSScreen.screens.map(\.frame) {
            for chord in chords {
                let anchor = LANGeometry.denormalize(CGPoint(x: 0.23, y: 0.71), in: frame)
                var pointer = anchor
                let input = GlobalInput(mouseButtonsDown: { false }, specialKeysDown: { [] }, mouseLocation: { pointer })
                input.configure(chord: chord)
                var committed: CGPoint?
                input.onAction = { if case .commit(_, let point) = $0 { committed = point } }
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
                // A stale point on another display is as wrong as an invalid one.
                event.location = .zero
                var flags: CGEventFlags = []
                if chord.modifiers.contains(.control) { flags.insert(.maskControl) }
                if chord.modifiers.contains(.option) { flags.insert(.maskAlternate) }
                if chord.modifiers.contains(.command) { flags.insert(.maskCommand) }
                if chord.modifiers.contains(.shift) { flags.insert(.maskShift) }
                event.flags = flags
                if !flags.isEmpty { _ = input.process(.flagsChanged, event) }
                for key in chord.keyCodes.sorted() {
                    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
                    _ = input.process(.keyDown, event)
                }
                _ = input.machine.delayElapsed()
                // Moving to choose a wheel sector must not move the Ping anchor.
                pointer = CGPoint(x: anchor.x+120, y: anchor.y)
                if let key = chord.keyCodes.sorted().first {
                    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
                    _ = input.process(.keyUp, event)
                } else { event.flags = []; _ = input.process(.flagsChanged, event) }
                if committed != anchor { failures += 1; print("FAIL shortcut commit lost the original display/pointer anchor") }
                input.stop()
            }
        }
        if failures == 0 { print("PASS shortcut positions: modifier-only, mixed and ordinary-key chords ignore stale keyboard-event coordinates") }
        return failures == 0 ? 0 : 1
    }
}
