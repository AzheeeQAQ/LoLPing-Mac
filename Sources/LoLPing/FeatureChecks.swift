import AppKit
import PingCore

/// No event taps, permission prompts, posted keyboard events or user preferences.
enum FeatureChecks {
    static func run(endpoint: String) -> Int32 {
        _ = NSApplication.shared
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL \(message)") }
        }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { spin(0.05) }
        }
        let input = GlobalInput()
        input.machine.chord = TriggerChord(modifiers: [.control], keyCode: 0)!
        var commits = 0, opened = 0
        input.onAction = { action in
            if case .commit = action { commits += 1 }
            if case .show = action { opened += 1 }
        }
        func flags(_ flags: CGEventFlags) {
            let event = CGEvent(source: nil)!
            event.flags = flags
            _ = input.process(.flagsChanged, event)
        }
        func key(_ code: CGKeyCode, down: Bool, modifiers: CGEventFlags = .maskControl) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = modifiers
            return input.process(down ? .keyDown : .keyUp, event)
        }
        flags(.maskControl)
        check(key(0, down: true), "trigger key down must be swallowed")
        check(key(0, down: true), "repeat must be swallowed")
        spin(0.25)
        check(opened == 1, "repeat must open only one wheel")
        check(key(0, down: false), "trigger key up must be swallowed")
        flags([])
        check(commits == 1, "key release must commit once")
        flags(.maskControl); check(key(0, down: true), "second gesture down")
        spin(0.25); flags([])
        check(key(0, down: false, modifiers: []), "modifier-first release must swallow key up")
        check(commits == 2, "modifier-first release must commit once")
        flags(.maskControl); _ = key(0, down: true); spin(0.25)
        check(key(53, down: true), "Escape must cancel and swallow")
        check(key(53, down: false), "Escape up must be balanced")
        check(key(0, down: false), "cancelled trigger up must be balanced")
        flags([]); check(commits == 2, "Escape must not send")
        flags(.maskControl); check(key(0, down: true), "short press down")
        check(key(0, down: false), "short press up")
        flags([]); spin(0.25)
        check(commits == 2, "short press must not send")
        check(!key(11, down: true, modifiers: []), "unrelated typing must pass through")
        check(!key(11, down: false, modifiers: []), "unrelated key up must pass through")
        input.stop()
        print("PASS event routing: repeat, balanced key events, both release orders, Escape, short press and ordinary typing")

        let suite = "LoLPing-FeatureChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("controlOptionShift", forKey: "triggerChord")
        let model = AppModel(defaults: defaults)
        model.relay.serverAddress = endpoint; model.relay.displayName = "开关测试甲"
        let peer = RelayClient(defaults: nil)
        peer.serverAddress = endpoint; peer.displayName = "开关测试乙"
        defer { model.shutdown(); peer.disconnect(); spin(0.2) }
        check(model.chord == .controlOptionShift, "old shortcut preference migration")
        model.chord = TriggerChord(modifiers: [.option, .shift], keyCode: 49)!
        let restored = AppModel(defaults: defaults)
        check(restored.chord == model.chord, "custom shortcut persistence")
        restored.shutdown()
        model.createRelayRoom(); spin(0.1)
        check(!model.relay.isActive, "disabled relay must not create a room")
        model.relayEnabled = true; model.createRelayRoom()
        wait { model.relay.state == .connected }
        check(model.relay.state == .connected, "enabled relay must connect")
        if model.relay.state != .connected { failures.append(model.relay.status) }
        else {
            peer.roomInput = model.relay.room; peer.joinRoom()
            wait { peer.state == .connected && model.relay.peers.count == 2 }
            check(peer.state == .connected, "peer must join")
            var received = 0
            peer.onPing = { _, _ in received += 1 }
            model.sendRelayTest(); wait { received == 1 }
            check(received == 1, "enabled relay must send")
            model.relay.reconnectAfterWake()
            model.relayEnabled = false
            spin(1.4)
            check(!model.relay.isActive && model.relay.state == .idle && model.relay.room.isEmpty, "off must cancel pending reconnect and clear room")
            model.sendRelayTest(); spin(0.3)
            check(received == 1, "disabled relay must not send")
            wait { peer.peers.count == 1 }
            check(peer.peers.count == 1, "off must free the room seat")
        }
        model.relayEnabled = true
        model.lanEnabled = true
        check(!model.relayEnabled && !model.relay.isActive, "LAN must disable relay")
        model.relayEnabled = true
        check(!model.lanEnabled && !model.relay.isActive, "relay switch must disable LAN without autojoining")
        let restoredEnabled = AppModel(defaults: defaults)
        restoredEnabled.restoreState()
        check(restoredEnabled.relayEnabled && !restoredEnabled.lanEnabled && !restoredEnabled.relay.isActive, "restore must retain switch without autojoining")
        restoredEnabled.shutdown()
        model.relayEnabled = false
        check(!defaults.bool(forKey: "relayEnabled"), "off preference must persist")
        if failures.isEmpty {
            print("PASS server switch: disabled guard, send, exit, pending reconnect, mutually exclusive LAN, persistence")
            print("All custom shortcut and server switch checks passed."); return 0
        }
        print("\(failures.count) feature check failures"); return 1
    }
}
