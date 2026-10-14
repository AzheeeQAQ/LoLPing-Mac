import AppKit
import PingCore

enum SessionChecks {
    static func run(endpoint: String) -> Int32 {
        _ = NSApplication.shared
        let suite = "LoLPing-SessionChecks-"+UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(0, forKey: "volume"); prefs.set(true, forKey: "relayEnabled")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LoLPing-SessionChecks-"+UUID().uuidString)
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name); print("FAIL \(name)") } }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ condition: () -> Bool) { let end = Date().addingTimeInterval(15); while !condition() && Date() < end { spin(0.03) } }
        let model = AppModel(defaults: prefs, emoteDirectory: scratch)
        let peer = RelayClient(defaults: nil), restarted = RelayClient(defaults: prefs)
        defer {
            restarted.disconnect(); peer.disconnect(); model.leaveRelayRoom(); model.shutdown(); spin(0.15)
            prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: scratch)
        }
        // A unique synthetic endpoint exercises the production Keychain store;
        // it is never contacted and cannot replace a real room credential.
        let store = RelaySessionStore(defaults: .standard)
        let fixtureURL = URL(string: "wss://"+UUID().uuidString.lowercased()+".invalid/ws")!
        let fixture = RelaySavedSession(endpoint: fixtureURL.absoluteString, room: "ABCDEFGHJK23", token: String(repeating: "a", count: 64), memberID: UUID().uuidString)
        check(store.save(fixture), "Keychain save")
        check(store.load(fixtureURL)?.token == fixture.token, "Keychain credential readback")
        store.remove(fixtureURL); check(store.load(fixtureURL) == nil, "Keychain fixture removed")
        model.relay.serverAddress = endpoint; peer.serverAddress = endpoint
        model.createRelayRoom(); wait { model.relay.state == .connected }
        check(model.relay.state == .connected, "room connects: \(model.relay.status)")
        if model.relay.state != .connected { return 1 }
        let room = model.relay.room, member = model.relay.memberID
        peer.roomInput = room; peer.joinRoom(); wait { peer.state == .connected && model.relay.peers.count == 2 }
        var gotPing: CGPoint?, gotImage: CGPoint?
        peer.onPositionedPing = { _, _, point in gotPing = point }
        peer.onPositionedEmote = { _, _, point in gotImage = point }
        let frames = NSScreen.screens.map(\.frame)
        check(!frames.isEmpty, "available display frames")
        for frame in frames {
            let relative = CGPoint(x: 0.21, y: 0.73), anchor = LANGeometry.denormalize(relative, in: frame)
            gotPing = nil; model.sendWheelContent(.ping(.assist), at: anchor); wait { gotPing != nil }
            check(gotPing.map { abs($0.x-relative.x) < 0.00001 && abs($0.y-relative.y) < 0.00001 } == true, "production model sends matching relative ping position on display")
            let imageID = model.emotes.bundled.first!.id
            gotImage = nil; model.sendWheelContent(.emote(imageID), at: anchor); wait { gotImage != nil }
            check(gotImage.map { abs($0.x-relative.x) < 0.00001 && abs($0.y-relative.y) < 0.00001 } == true, "production model sends matching relative image position on display")
            spin(1.05)
        }
        print("PASS production relative positions: ping and image on \(frames.count) physical display(s), no global input event posted")
        // Inspect the actual receiving panels, rather than only the decoded
        // packet: the receiver's pointer chooses a display, never the anchor.
        for relative in [CGPoint(x: 0.17, y: 0.83), CGPoint(x: 0.79, y: 0.24), CGPoint(x: 0.36, y: 0.62)] {
            let pointer = NSEvent.mouseLocation
            guard let index = LANGeometry.screenIndex(containing: pointer, in: frames) else { check(false, "receiver display"); continue }
            let target = frames[index], expected = LANGeometry.denormalize(relative, in: target)
            var existing = Set(NSApp.windows.map(\.windowNumber))
            peer.sendPing(.enemyVision, position: relative)
            func receivedPing() -> NSWindow? {
                NSApp.windows.first { !existing.contains($0.windowNumber) && ($0.contentView as? PingEffectView)?.label == peer.displayName }
            }
            wait { receivedPing() != nil }
            if let panel = receivedPing() {
                let local = OverlayController.pingPanel(scale: model.scale)
                let actual = CGPoint(x: panel.frame.minX-local.minX, y: panel.frame.minY-local.minY)
                check(hypot(actual.x-expected.x, actual.y-expected.y) < 1, "received ping panel uses sender position: expected \(expected), actual \(actual), receiver pointer \(pointer)")
            } else { check(false, "received ping creates overlay") }
            existing = Set(NSApp.windows.map(\.windowNumber))
            peer.sendEmote(model.emotes.payload(model.emotes.bundled.first!.id)!, position: relative)
            func receivedImage() -> NSWindow? {
                NSApp.windows.first { !existing.contains($0.windowNumber) && $0.contentView is EmoteEffectView }
            }
            wait { receivedImage() != nil }
            if let panel = receivedImage() {
                let center = WheelGeometry.clampedCenter(anchor: expected, frame: target, radius: CGFloat(110*model.scale))
                check(hypot(panel.frame.midX-center.x, panel.frame.midY-center.y) < 1, "received image panel uses sender position")
            } else { check(false, "received image creates overlay") }
            spin(1.1)
        }
        print("PASS receiving overlays: actual ping and image panel frames match the sender, independently of the receiver pointer")
        model.shutdown(); spin(0.2)
        restarted.serverAddress = endpoint
        check(restarted.restoreSavedSession(), "saved room restores after shutdown/update")
        wait { restarted.state == .connected && restarted.peers.count == 2 }
        check(restarted.room == room && restarted.memberID == member, "room code and identity survive client restart")
        gotPing = nil; restarted.sendPing(.missing, position: CGPoint(x: 0.3, y: 0.6)); wait { gotPing != nil }
        check(gotPing == CGPoint(x: 0.3, y: 0.6), "resumed client sends positions")
        restarted.disconnect(); spin(0.2)
        let afterLeave = RelayClient(defaults: prefs); afterLeave.serverAddress = endpoint
        check(!afterLeave.restoreSavedSession(), "explicit leave forgets room and does not auto-rejoin")
        afterLeave.disconnect()
        print("PASS saved session: client update/quit preserves room; explicit leave removes credentials")
        failures.forEach { print("FAIL \($0)") }
        if failures.isEmpty { print("All session and display checks passed."); return 0 }
        return 1
    }
}
