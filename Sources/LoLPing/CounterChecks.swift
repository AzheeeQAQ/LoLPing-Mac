import AppKit
import SwiftUI
import PingCore

/// Production relay and LAN clients only: no input taps, overlays, audio or preferences.
enum CounterChecks {
    @discardableResult
    private static func spin(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }
    private static func fail(_ message: String) -> Int32 { print("FAIL Counter check: \(message)"); return 1 }

    static func relay(endpoint: String) -> Int32 {
        let a = RelayClient(defaults: nil), b = RelayClient(defaults: nil)
        var failure: String?
        for client in [a, b] { client.serverAddress = endpoint; client.onFailure = { failure = $0 } }
        defer { a.disconnect(); b.disconnect(); spin(0.3) { false } }
        a.displayName = "甲"; b.displayName = "乙"
        let day = DailyCounter.dayKey(for: Date())
        a.localCounter = DailyCounter(day: day, today: 2, total: 20)
        b.localCounter = DailyCounter(day: day, today: 7, total: 7)
        a.createRoom()
        guard spin(8, until: { a.state == .connected || failure != nil }), failure == nil else { return fail(failure ?? "A did not connect: \(a.status)") }
        b.roomInput = a.formattedRoom; b.joinRoom()
        guard spin(8, until: { b.friendCounters.first?.counter == a.localCounter && a.friendCounters.first?.counter == b.localCounter }) else {
            return fail("join exchange: A sees \(a.friendCounters.map(\.counter)), B sees \(b.friendCounters.map(\.counter)); \(failure ?? "")")
        }
        guard a.friendCounters.first?.peer.name == "乙", b.friendCounters.first?.peer.name == "甲" else { return fail("sender names") }
        print("PASS counter relay: both friends see each other's counter right after joining")
        var burst = a.localCounter!
        for _ in 0..<25 { burst.increment(at: Date()); a.localCounter = burst }
        burst.decrement(at: Date()); a.localCounter = burst
        guard spin(8, until: { b.friendCounters.first?.counter == burst }) else { return fail("burst ended on \(b.friendCounters.map(\.counter))") }
        guard failure == nil, !a.status.contains("太快") else { return fail("burst hit limits: \(a.status)") }
        print("PASS counter relay: a 26-click burst lands on the latest value without hitting rate limits")
        b.reconnectAfterWake()
        guard spin(1, until: { b.state != .connected }) else { return fail("B did not drop for the reconnect test") }
        guard spin(15, until: { b.state == .connected && b.friendCounters.first?.counter == burst && a.friendCounters.first?.counter == b.localCounter }) else {
            return fail("after reconnect B sees \(b.friendCounters.map(\.counter)) (\(b.status))")
        }
        print("PASS counter relay: after a reconnect both counters come back without anyone clicking")
        print("All counter relay checks passed."); return 0
    }

    /// Drives the real AppModel (temporary preferences and emote folder) with one
    /// friend over a local relay, then one over LAN, and renders the window each time.
    static func ui(directory: URL, endpoint: String) -> Int32 {
        _ = NSApplication.shared
        let suite = "LoLPing-CounterChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let emoteFolder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: emoteFolder) }
        let day = DailyCounter.dayKey(for: Date())
        defaults.set(day, forKey: "counterDay"); defaults.set(12, forKey: "counterToday"); defaults.set(340, forKey: "counterTotal")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(defaults: defaults, emoteDirectory: emoteFolder)
        defer { model.relay.disconnect(); model.lanEnabled = false; model.shutdown(); spin(0.3) { false } }
        guard model.counter.state == DailyCounter(day: day, today: 12, total: 340) else { return fail("saved counter not restored") }

        model.relayEnabled = true; model.relay.serverAddress = endpoint; model.relay.displayName = "我"
        let friend = RelayClient(defaults: nil)
        friend.serverAddress = endpoint; friend.displayName = "小红"
        friend.localCounter = DailyCounter(day: day, today: 5, total: 87)
        defer { friend.disconnect() }
        model.createRelayRoom()
        guard spin(8, until: { model.relay.state == .connected }) else { return fail("model did not connect: \(model.relay.status)") }
        friend.roomInput = model.relay.formattedRoom; friend.joinRoom()
        guard spin(8, until: { model.relay.friendCounters.count == 1 && friend.friendCounters.first?.counter == model.counter.state }) else {
            return fail("relay friend row: \(model.relay.friendCounters.map(\.counter)) / \(friend.friendCounters.map(\.counter))")
        }
        model.counter.increment()
        guard spin(5, until: { friend.friendCounters.first?.counter == DailyCounter(day: day, today: 13, total: 341) }) else {
            return fail("+ did not reach the relay friend: \(friend.friendCounters.map(\.counter))")
        }
        guard render(model, to: directory.appendingPathComponent("counter-relay.png")) else { return fail("render relay") }
        print("PASS counter UI: + in the app reaches a server friend; window rendered with the friend row")
        friend.disconnect(); model.leaveRelayRoom()

        let room = "UI" + String(UUID().uuidString.prefix(6))
        model.lanEnabled = true
        model.lanNicknameDraft = "我"; model.lanRoomDraft = room; model.commitLANDrafts()
        let lanFriend = LANSession()
        var lanPeers = LANSession.Peers()
        lanFriend.onPeers = { lanPeers = $0 }
        lanFriend.setCounter(DailyCounter(day: day, today: 2, total: 9))
        defer { lanFriend.stop() }
        lanFriend.start(room: room, name: "阿杰")
        guard spin(20, until: { model.lanPeers.counters.count == 1 && lanPeers.counters.first?.counter == model.counter.state }) else {
            return fail("LAN friend row: \(model.lanPeers) / \(lanPeers.counters); \(model.lanStatusText)")
        }
        model.counter.decrement()
        guard spin(5, until: { lanPeers.counters.first?.counter == DailyCounter(day: day, today: 12, total: 340) }) else {
            return fail("- did not reach the LAN friend: \(lanPeers.counters)")
        }
        guard render(model, to: directory.appendingPathComponent("counter-lan.png")) else { return fail("render LAN") }
        print("PASS counter UI: - in the app reaches a LAN friend; window rendered with the friend row")
        print("All counter UI checks passed: \(directory.path)"); return 0
    }
    private static func render(_ model: AppModel, to url: URL) -> Bool {
        let host = NSHostingView(rootView: ControlView(model: model))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: 680, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        spin(0.5) { false }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        do { try rep.representation(using: .png, properties: [:])?.write(to: url) } catch { return false }
        withExtendedLifetime(window) {}
        return true
    }

    static func lan() -> Int32 {
        let a = LANSession(), b = LANSession()
        var peersA = LANSession.Peers(), peersB = LANSession.Peers(), problem: String?
        a.onPeers = { peersA = $0 }; b.onPeers = { peersB = $0 }
        for session in [a, b] { session.onStatus = { if let text = $0.problem { problem = text } } }
        defer { a.stop(); b.stop() }
        let day = DailyCounter.dayKey(for: Date())
        let first = DailyCounter(day: day, today: 1, total: 11), second = DailyCounter(day: day, today: 4, total: 4)
        a.setCounter(first); b.setCounter(second)
        let room = "CNT" + String(UUID().uuidString.prefix(5))
        a.start(room: room, name: "甲"); b.start(room: room, name: "乙")
        guard spin(20, until: { peersA.counters.first?.counter == second && peersB.counters.first?.counter == first }) else {
            return fail("LAN exchange: A sees \(peersA.counters), B sees \(peersB.counters); \(problem ?? "no status problem")")
        }
        guard peersA.counters.first?.name == "乙", peersB.counters.first?.name == "甲" else { return fail("LAN names") }
        print("PASS counter LAN: both friends see each other's counter")
        var next = first; next.increment(at: Date()); next.increment(at: Date())
        let changed = Date()
        a.setCounter(next)
        guard spin(5, until: { peersB.counters.first?.counter == next }) else { return fail("LAN update: B sees \(peersB.counters)") }
        // Peer lists are coalesced every 0.25 s; hellos are every 3 s, so this proves the immediate send.
        let delay = Date().timeIntervalSince(changed)
        guard delay < 1.5 else { return fail(String(format: "LAN update took %.2f s (waited for a periodic hello)", delay)) }
        print(String(format: "PASS counter LAN: a change reaches the friend in %.2f s", delay))
        print("All counter LAN checks passed."); return 0
    }
}
