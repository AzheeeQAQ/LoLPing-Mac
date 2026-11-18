import AppKit
import SwiftUI
import PingCore

/// Production relay and LAN clients only: no input taps, audio or preferences.
enum CounterChecks {
    @discardableResult
    private static func spin(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }
    private static func fail(_ message: String) -> Int32 { print("FAIL Counter check: \(message)"); return 1 }
    private static func show(_ counter: DailyCounter?) -> String { counter.map { "\($0.today)/\($0.total)" } ?? "nil" }

    /// Two production clients share one room counter through the relay.
    static func relay(endpoint: String) -> Int32 {
        let a = RelayClient(defaults: nil), b = RelayClient(defaults: nil)
        var failure: String?, popups: [(delta: Int, name: String)] = []
        for client in [a, b] { client.serverAddress = endpoint; client.onFailure = { failure = $0 } }
        b.onRoomCounterChange = { delta, name, _ in popups.append((delta, name)) }
        defer { a.disconnect(); b.disconnect(); spin(0.3) { false } }
        a.displayName = "甲"; b.displayName = "乙"
        let day = DailyCounter.dayKey(for: Date())
        a.localCounter = DailyCounter(day: day, today: 2, total: 20)
        b.localCounter = DailyCounter(day: day, today: 7, total: 7)
        a.createRoom()
        guard spin(8, until: { a.state == .connected || failure != nil }), failure == nil else { return fail(failure ?? "A did not connect: \(a.status)") }
        b.roomInput = a.formattedRoom; b.joinRoom()
        let merged = DailyCounter(day: day, today: 9, total: 27)
        guard spin(8, until: { a.roomCounter == merged && b.roomCounter == merged }) else {
            return fail("seed merge: A \(show(a.roomCounter)), B \(show(b.roomCounter)); \(failure ?? "")")
        }
        print("PASS shared counter: both personal counts are added once when the room is shared")
        guard a.changeRoomCounter(1) == DailyCounter(day: day, today: 10, total: 28) else { return fail("optimistic +1") }
        guard spin(5, until: { b.roomCounter?.today == 10 && popups.count == 1 }), popups[0].delta == 1, popups[0].name == "甲" else {
            return fail("friend click: B sees \(show(b.roomCounter)), popups \(popups)")
        }
        print("PASS shared counter: a click shows at once for the clicker and pops up for the friend with the name")
        // Both click at the same time: 13 from A, 12 from B, then B takes back 2.
        for index in 0..<25 { if index % 2 == 0 { a.changeRoomCounter(1) } else { b.changeRoomCounter(1) } }
        b.changeRoomCounter(-1); b.changeRoomCounter(-1)
        let final = DailyCounter(day: day, today: 33, total: 51)
        guard spin(8, until: { a.roomCounter == final && b.roomCounter == final && a.pendingCounterDelta == 0 && b.pendingCounterDelta == 0 }) else {
            return fail("concurrent clicks: A \(show(a.roomCounter)) B \(show(b.roomCounter))")
        }
        guard failure == nil, !a.status.contains("太快"), !b.status.contains("太快") else { return fail("rate limit: \(a.status) / \(b.status)") }
        print("PASS shared counter: 27 simultaneous clicks from both sides add up exactly, no rate limit")
        guard a.supportsCounterHistory, b.supportsCounterHistory else { return fail("relay does not keep daily counts (counter-history-v1)") }
        guard a.roomHistory.days == [day: 33], b.roomHistory.days == [day: 33] else {
            return fail("daily history: A \(a.roomHistory.days) B \(b.roomHistory.days)")
        }
        print("PASS daily chart: today's point follows the shared counter on both sides")
        b.reconnectAfterWake()
        guard spin(1, until: { b.state != .connected }), b.roomCounter == final else { return fail("B should keep the number while reconnecting") }
        guard spin(15, until: { b.sharedCounterReady && b.roomCounter == final && a.roomCounter == final }) else {
            return fail("after reconnect: \(show(b.roomCounter)) (\(b.status))")
        }
        guard b.roomHistory.days == [day: 33] else { return fail("daily history after reconnect: \(b.roomHistory.days)") }
        print("PASS shared counter: the number stays through a reconnect and the personal count is not added twice")
        print("All shared counter relay checks passed."); return 0
    }

    /// With relay/test/counter-history-client-check.mjs, which writes past days into
    /// the room right after it is created: they reach the friend on join and us on reconnect.
    static func history(endpoint: String) -> Int32 {
        let a = RelayClient(defaults: nil), b = RelayClient(defaults: nil)
        var failure: String?
        for client in [a, b] { client.serverAddress = endpoint; client.onFailure = { failure = $0 } }
        defer { a.disconnect(); b.disconnect(); spin(0.3) { false } }
        a.displayName = "甲"; b.displayName = "乙"
        let now = Date()
        func day(_ offset: Int) -> String { DailyCounter.dayKey(daysBefore: offset, from: now) }
        a.createRoom()
        guard spin(8, until: { a.state == .connected || failure != nil }), failure == nil else { return fail(failure ?? "A did not connect") }
        guard a.supportsCounterHistory, a.roomHistory.days.isEmpty else { return fail("new room: \(a.roomHistory.days)") }
        a.changeRoomCounter(1); a.changeRoomCounter(1)
        guard spin(5, until: { a.roomCounter?.today == 2 && a.pendingCounterDelta == 0 }), a.roomHistory.days == [day(0): 2] else {
            return fail("today's clicks: \(a.roomHistory.days)")
        }
        b.roomInput = a.formattedRoom; b.joinRoom()
        // The harness wrote 4 yesterday, 2 three days ago and 9 at 95 days ago (outside the 90 days).
        let expected = [day(1): 4, day(3): 2, day(0): 2]
        guard spin(8, until: { b.roomHistory.days == expected }) else { return fail("friend's history on join: \(b.roomHistory.days); \(failure ?? "")") }
        let series = b.roomHistory.series(days: 7, endingAt: now, live: b.roomCounterDisplay).map(\.count)
        guard series == [0, 0, 0, 2, 0, 4, 2] else { return fail("7-day series \(series)") }
        print("PASS daily chart: a friend joining sees the room's past days; days past 90 are dropped")
        b.changeRoomCounter(1)
        guard spin(5, until: { a.roomHistory.days[day(0)] == 3 && b.roomHistory.days[day(0)] == 3 }) else {
            return fail("friend's click on the chart: A \(a.roomHistory.days) B \(b.roomHistory.days)")
        }
        a.reconnectAfterWake()
        guard spin(15, until: { a.sharedCounterReady && a.roomHistory.days == [day(1): 4, day(3): 2, day(0): 3] }) else {
            return fail("history after reconnect: \(a.roomHistory.days) (\(a.status))")
        }
        print("PASS daily chart: clicks from either side update today's point; a reconnect brings the past days back")
        a.disconnect()
        guard spin(2, until: { a.roomHistory.days.isEmpty }) else { return fail("leaving should clear the room's history") }
        print("All daily chart relay checks passed."); return 0
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
        let personal = DailyCounter(day: day, today: 12, total: 340)
        defaults.set(day, forKey: "counterDay"); defaults.set(12, forKey: "counterToday"); defaults.set(340, forKey: "counterTotal")
        let pattern = [0, 3, 5, 2, 0, 7, 4, 1, 6, 0, 2, 8, 3]
        var past: [String: Int] = [:]
        for offset in 1..<CounterHistory.keptDays where pattern[offset % pattern.count] > 0 {
            past[DailyCounter.dayKey(daysBefore: offset, from: Date())] = pattern[offset % pattern.count]
        }
        past[DailyCounter.dayKey(daysBefore: 120, from: Date())] = 50  // older than 90 days: dropped on load
        defaults.set(past, forKey: "counterHistory")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(defaults: defaults, emoteDirectory: emoteFolder)
        defer { model.relay.disconnect(); model.lanEnabled = false; model.shutdown(); spin(0.3) { false } }
        guard model.counter.state == personal else { return fail("saved counter not restored") }
        var expectedHistory = past; expectedHistory[DailyCounter.dayKey(daysBefore: 120, from: Date())] = nil; expectedHistory[day] = 12
        guard model.counter.history.days == expectedHistory else { return fail("saved daily history not restored: \(model.counter.history.days.count) days") }
        guard CounterTrendView.labelIndices(7) == Array(0..<7), CounterTrendView.labelIndices(30) == [1, 8, 15, 22, 29],
              CounterTrendView.labelIndices(90) == [14, 29, 44, 59, 74, 89], CounterTrendView.shortLabel("2026-11-07") == "11/7",
              CounterTrendView.longLabel("2026-11-17") == "11月17日 周二", model.counterChartShown, model.counterChartDays == 7 else {
            return fail("chart labels or defaults")
        }

        model.relayEnabled = true; model.relay.serverAddress = endpoint; model.relay.displayName = "我"
        let friend = RelayClient(defaults: nil)
        friend.serverAddress = endpoint; friend.displayName = "小红"
        friend.localCounter = DailyCounter(day: day, today: 5, total: 87)
        var friendPopups: [(delta: Int, name: String)] = []
        friend.onRoomCounterChange = { delta, name, _ in friendPopups.append((delta, name)) }
        defer { friend.disconnect() }
        model.createRelayRoom()
        guard spin(8, until: { model.relay.state == .connected && model.sharedCounterActive }) else { return fail("model did not connect: \(model.relay.status)") }
        friend.roomInput = model.relay.formattedRoom; friend.joinRoom()
        guard spin(8, until: { model.relay.roomCounter == DailyCounter(day: day, today: 17, total: 427) && friend.roomCounter == model.relay.roomCounter }) else {
            return fail("shared seed: \(show(model.relay.roomCounter)) / \(show(friend.roomCounter))")
        }
        model.changeCounter(1)
        guard model.counterToastCount == 1 else { return fail("no pop-up for our own click") }
        guard spin(5, until: { friend.roomCounter?.today == 18 && friendPopups.count == 1 }), friendPopups[0].delta == 1, friendPopups[0].name == "我" else {
            return fail("+ did not reach the friend: \(show(friend.roomCounter)) \(friendPopups)")
        }
        guard model.counter.state == personal else { return fail("room clicks must not touch the personal counter") }
        friend.changeRoomCounter(1)
        guard spin(5, until: { model.relay.roomCounter?.today == 19 && model.counterToastCount == 2 }) else {
            return fail("friend click did not pop up here: \(show(model.relay.roomCounter)), pop-ups \(model.counterToastCount)")
        }
        guard render(model, to: directory.appendingPathComponent("counter-shared.png")) else { return fail("render shared") }
        guard renderToasts(to: directory.appendingPathComponent("counter-toasts.png"), day: day) else { return fail("render pop-ups") }
        print("PASS counter UI: shared room counter; + pops up here and at the friend, the friend's + pops up here")
        friend.disconnect(); model.leaveRelayRoom()
        guard spin(2, until: { !model.sharedCounterActive }), model.counter.state == personal else { return fail("leaving should show the personal counter again") }
        model.counterChartDays = 30
        guard render(model, to: directory.appendingPathComponent("counter-chart-30.png")) else { return fail("render 30-day chart") }
        for (days, hover) in [(7, nil), (90, nil), (30, 26)] as [(Int, Int?)] {
            let view = CounterTrendView(history: model.counter.history, live: model.counter.state, shared: false, days: .constant(days), hovered: hover)
            guard renderTrend(view, to: directory.appendingPathComponent("counter-chart-\(days)\(hover == nil ? "" : "-hover").png")) else { return fail("render \(days)-day chart") }
        }
        guard defaults.integer(forKey: "counterChartDays") == 30 else { return fail("chart range not saved") }
        print("PASS counter UI: daily chart at 7 / 30 / 90 days from the saved history; the range is remembered")

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
        model.changeCounter(-1)
        guard spin(5, until: { lanPeers.counters.first?.counter == DailyCounter(day: day, today: 11, total: 339) }), model.counterToastCount >= 1 else {
            return fail("- did not reach the LAN friend: \(lanPeers.counters)")
        }
        guard model.counter.history.days[day] == 11, (defaults.dictionary(forKey: "counterHistory") as? [String: Int])?[day] == 11 else {
            return fail("personal click not in the saved daily history")
        }
        guard render(model, to: directory.appendingPathComponent("counter-lan.png")) else { return fail("render LAN") }
        print("PASS counter UI: LAN keeps personal counters; - pops up and reaches the LAN friend")
        print("All counter UI checks passed: \(directory.path)"); return 0
    }
    private static func renderToasts(to url: URL, day: String) -> Bool {
        let views = [CounterToastView(delta: 1, counter: DailyCounter(day: day, today: 18, total: 428), name: nil),
                     CounterToastView(delta: 1, counter: DailyCounter(day: day, today: 19, total: 429), name: "小红"),
                     CounterToastView(delta: -1, counter: DailyCounter(day: day, today: 18, total: 428), name: "小红")]
        let width = views.map(\.frame.width).reduce(0, +) + 40, height = views.map(\.frame.height).max()! + 20
        let rep = VisualChecks.bitmap(size: CGSize(width: width, height: height)) {
            var x: CGFloat = 10
            for view in views { view.seek(to: 0.3); VisualChecks.draw(view, at: CGPoint(x: x, y: 10)); x += view.frame.width + 10 }
        }
        return (try? VisualChecks.save(rep, to: url)) != nil
    }
    private static func renderTrend(_ trend: CounterTrendView, to url: URL) -> Bool {
        let host = NSHostingView(rootView: trend.padding(16).frame(width: 628).background(Palette.card).preferredColorScheme(.dark).tint(Palette.gold))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: CGSize(width: 628, height: host.fittingSize.height))
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
