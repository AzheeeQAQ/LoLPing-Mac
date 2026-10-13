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
        let input = GlobalInput(mouseButtonsDown: { false })
        input.configure(chord: TriggerChord(modifiers: [.control], keyCode: 0)!)
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
        input.configure(chord: TriggerChord(modifiers: [.command], keyCodes: [0,11,76,117])!)
        flags(.maskCommand)
        for code: CGKeyCode in [76,117,0,11] { check(key(code, down: true, modifiers: .maskCommand), "multi-key prefix is balanced and swallowed") }
        spin(0.23)
        let beforeMultiRelease = commits
        for code: CGKeyCode in [117,76,11,0] { check(key(code, down: false, modifiers: .maskCommand), "multi-key release is balanced") }
        flags([]); check(commits == beforeMultiRelease+1, "multi-key release commits exactly once")
        input.stop()
        input.configure(chord: TriggerChord(modifiers: [], keyCode: 53)!)
        check(key(53, down: true, modifiers: []), "Escape is recordable as a trigger")
        spin(0.23); let beforeEscapeRelease = commits
        check(key(53, down: false, modifiers: []), "configured Escape release is balanced")
        check(commits == beforeEscapeRelease+1, "configured Escape sends rather than cancels")
        input.stop()
        var specials: Modifiers = []
        let specialInput = GlobalInput(mouseButtonsDown: { false }, specialKeysDown: { specials })
        var specialCommits = 0
        specialInput.onAction = { if case .commit = $0 { specialCommits += 1 } }
        for modifier: Modifiers in [.function, .capsLock] {
            specialInput.stop(); specialInput.configure(chord: TriggerChord(modifiers: modifier)!)
            let event = CGEvent(source: nil)!; event.flags = .maskAlphaShift
            _ = specialInput.process(.flagsChanged, event)
            check(specialInput.machine.phase == .idle, "latched Caps flag alone must not trigger a physical key")
            specials = modifier; _ = specialInput.process(.flagsChanged, event); spin(0.23)
            specials = []; _ = specialInput.process(.flagsChanged, event)
        }
        check(specialCommits == 2, "physical Fn/Caps pressed and released exactly once")
        specialInput.stop()
        for (code, modifier): (CGKeyCode, Modifiers) in [(63, .function), (57, .capsLock)] {
            specialInput.configure(chord: TriggerChord(modifiers: modifier)!)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
            down.flags = []; up.flags = []
            check(!specialInput.process(.keyDown, down), "special modifier driver events pass through")
            spin(0.23)
            check(!specialInput.process(.keyUp, up), "special modifier driver release passes through")
            specialInput.stop()
        }
        check(specialCommits == 4, "Fn/Caps keyboard-driver events send exactly once")
        input.configure(chord: TriggerChord(modifiers: [], keyCode: 65552)!)
        let beforeMedia = commits
        for down in [true,false] {
            let media = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          subtype: 8, data1: (16 << 16) | ((down ? 10 : 11) << 8), data2: -1)!
            check(KeyboardEvent.keyChange(media)?.key == 65552, "media key decoding")
            check(input.process(CGEventType(rawValue: 14)!, media.cgEvent!), "media trigger is balanced")
            if down { spin(0.23) }
        }
        check(commits == beforeMedia+1, "media key gesture sends once")
        input.stop()
        print("PASS expanded event routing: multi-key prefixes/releases, Escape, media keys and physical Fn/Caps")

        let suite = "LoLPing-FeatureChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("controlOptionShift", forKey: "triggerChord")
        let model = AppModel(defaults: defaults)
        model.relay.serverAddress = endpoint; model.relay.displayName = "开关测试甲"
        let peer = RelayClient(defaults: nil)
        peer.serverAddress = endpoint; peer.displayName = "开关测试乙"
        defer { model.shutdown(); peer.disconnect(); spin(0.2) }
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString(" abcd-efgh-jklm \n", forType: .string)
        model.relay.pasteRoomCode(from: clipboard)
        check(model.relay.roomInput == "ABCDEFGHJKLM" && !model.relay.isActive, "paste formatted room without joining")
        clipboard.clearContents(); clipboard.setString("not a room", forType: .string)
        model.relay.pasteRoomCode(from: clipboard)
        check(model.relay.roomInput == "ABCDEFGHJKLM", "invalid clipboard preserves entered room")
        clipboard.clearContents(); model.relay.pasteRoomCode(from: clipboard)
        check(model.relay.roomInput == "ABCDEFGHJKLM", "empty clipboard preserves entered room")
        clipboard.setString(" 91\n37 ", forType: .string)
        model.pasteLANRoomCode(from: clipboard)
        check(model.lanRoomCode == "9137" && model.lanRoomDraft == "9137", "paste LAN room")
        print("PASS room paste: formatted server code, invalid/empty clipboard, no automatic join and LAN")
        check(model.chord == .controlOptionShift, "old shortcut preference migration")
        model.chord = TriggerChord(modifiers: [.option, .shift], keyCode: 49)!
        let restored = AppModel(defaults: defaults)
        check(restored.chord == model.chord, "custom shortcut persistence")
        restored.shutdown()
        model.chord = TriggerChord(modifiers: [.control, .function], keyCodes: [53,76])!
        let restoredRecording = AppModel(defaults: defaults)
        check(restoredRecording.chord == model.chord, "recorded multi-key/Fn shortcut persists")
        restoredRecording.shutdown()
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
            let originalRoom = model.relay.room
            clipboard.clearContents(); clipboard.setString("ABCD-EFGH-JKLM", forType: .string)
            model.relay.pasteRoomCode(from: clipboard)
            check(model.relay.isActive && model.relay.room == originalRoom && model.relay.roomInput == "ABCDEFGHJKLM", "connected paste edits without leaving room")
            model.relay.roomInput = "bad"; model.joinRelayRoom(); spin(0.1)
            check(model.relay.state == .connected && model.relay.room == originalRoom && peer.peers.count == 2, "invalid switch input preserves active room")
            model.relay.roomInput = originalRoom
            model.relay.reconnectAfterWake()
            model.relayEnabled = false
            spin(1.4)
            check(!model.relay.isActive && model.relay.state == .idle && model.relay.room.isEmpty, "off must cancel pending reconnect and clear room")
            model.sendRelayTest(); spin(0.3)
            check(received == 1, "disabled relay must not send")
            wait { peer.peers.count == 1 }
            check(peer.peers.count == 1, "off must free the room seat")
            let otherHost = RelayClient(defaults: nil)
            otherHost.serverAddress = endpoint; otherHost.displayName = "切房测试"
            defer { otherHost.disconnect() }
            otherHost.createRoom(); wait { otherHost.state == .connected }
            model.relayEnabled = true; model.relay.roomInput = originalRoom; model.joinRelayRoom()
            wait { model.relay.state == .connected && peer.peers.count == 2 }
            clipboard.clearContents(); clipboard.setString(otherHost.formattedRoom, forType: .string)
            model.relay.pasteRoomCode(from: clipboard); model.joinRelayRoom()
            wait { model.relay.state == .connected && model.relay.room == otherHost.room && otherHost.peers.count == 2 && peer.peers.count == 1 }
            check(model.relay.room == otherHost.room && peer.peers.count == 1, "explicit room switch frees old seat and joins pasted room")
            model.relayEnabled = false
            print("PASS connected room paste: no automatic switch, invalid input preserves room, explicit switch joins new room")
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
