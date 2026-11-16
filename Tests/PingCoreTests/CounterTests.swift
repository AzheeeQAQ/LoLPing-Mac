import Foundation
import PingCore

final class CounterTests {
    let iso = ISO8601DateFormatter()
    var lastSecond: Date { iso.date(from: "2026-11-12T15:59:59Z")! }  // UTC+8 11-12 23:59:59
    var midnight: Date { iso.date(from: "2026-11-12T16:00:00Z")! }    // UTC+8 11-13 00:00:00

    func testResetsAtUTC8Midnight() {
        XCTAssertEqual(DailyCounter.dayKey(for: lastSecond), "2026-11-12")
        XCTAssertEqual(DailyCounter.dayKey(for: midnight), "2026-11-13")
        XCTAssertEqual(DailyCounter.nextReset(after: iso.date(from: "2026-11-12T03:00:00Z")!), midnight)
        XCTAssertEqual(DailyCounter.nextReset(after: midnight), iso.date(from: "2026-11-13T16:00:00Z")!)
        var counter = DailyCounter(day: "", today: 0, total: 0)
        counter.increment(at: lastSecond); counter.increment(at: lastSecond)
        XCTAssertEqual([counter.today, counter.total], [2, 2])
        XCTAssertEqual(counter.rollover(at: lastSecond), false)
        XCTAssertEqual(counter.rollover(at: midnight), true)
        XCTAssertEqual([counter.today, counter.total], [0, 2])
        counter.decrement(at: midnight)
        XCTAssertEqual([counter.today, counter.total], [0, 2])
        counter.increment(at: midnight); counter.decrement(at: midnight); counter.increment(at: midnight)
        XCTAssertEqual([counter.today, counter.total], [1, 3])
        var stale = DailyCounter(day: "2026-11-12", today: 5, total: 9)
        stale.increment(at: midnight)
        XCTAssertEqual([stale.today, stale.total], [1, 10])
        let corrupt = DailyCounter(day: "x", today: -3, total: -1)
        XCTAssertEqual([corrupt.today, corrupt.total], [0, 0])
        // A friend's snapshot from yesterday shows 0 today but keeps the total.
        let friend = DailyCounter(day: "2026-11-12", today: 4, total: 40)
        XCTAssertEqual(friend.today(at: lastSecond), 4)
        XCTAssertEqual(friend.today(at: midnight), 0)
    }
    func testWireFormatsAndValidation() {
        XCTAssertEqual(DailyCounter.received(day: "2026-11-13", today: 2, total: 5), DailyCounter(day: "2026-11-13", today: 2, total: 5))
        for (day, today, total) in [("2026-1-13", 1, 1), ("２０２６-11-13", 1, 1), ("2026-11-13", -1, 1), ("2026-11-13", 3, 2),
                                    ("2026-11-13", 0, DailyCounter.maxValue+1)] {
            XCTAssertEqual(DailyCounter.received(day: day, today: today, total: total), nil)
        }
        XCTAssertEqual(DailyCounter.received(day: nil, today: 1, total: 1), nil)
        // Relay: round trip, and an invalid snapshot fails the decode (the server never forwards one).
        var message = RelayMessage(type: "counter"); message.counter = DailyCounter(day: "2026-11-13", today: 2, total: 5)
        let data = try! JSONEncoder().encode(message)
        let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        XCTAssertEqual(fields["counter"] as? [String: AnyHashable], ["day": "2026-11-13", "today": 2, "total": 5])
        XCTAssertEqual(try? JSONDecoder().decode(RelayMessage.self, from: data).counter, message.counter)
        let bad = Data(#"{"type":"counter","counter":{"day":"2026-11-13","today":9,"total":1}}"#.utf8)
        XCTAssertEqual((try? JSONDecoder().decode(RelayMessage.self, from: bad)) == nil, true)
        XCTAssertEqual(try? JSONDecoder().decode(RelayMessage.self, from: Data(#"{"type":"ping"}"#.utf8)).counter, nil)
    }
    func testSharedCounterRules() {
        // Same clamping as the relay: never below 0 today, total moves by what was applied.
        var counter = DailyCounter(day: "2026-11-12", today: 2, total: 10)
        XCTAssertEqual(counter.apply(-5, at: lastSecond), -2)
        XCTAssertEqual([counter.today, counter.total], [0, 8])
        XCTAssertEqual(counter.apply(-1, at: lastSecond), 0)
        XCTAssertEqual(counter.apply(3, at: lastSecond), 3)
        XCTAssertEqual([counter.today, counter.total], [3, 11])
        XCTAssertEqual(counter.apply(1, at: midnight), 1)
        XCTAssertEqual([counter.today, counter.total], [1, 12])
        var full = DailyCounter(day: "2026-11-13", today: 0, total: DailyCounter.maxValue-1)
        XCTAssertEqual(full.apply(5, at: lastSecond), 1)
        // Wire format of the shared counter messages.
        var hello = RelayMessage(type: "hello"); hello.counterSeed = DailyCounter(day: "2026-11-13", today: 1, total: 6)
        let fields = (try? JSONSerialization.jsonObject(with: try! JSONEncoder().encode(hello))) as? [String: Any] ?? [:]
        XCTAssertEqual(fields["counterSeed"] as? [String: AnyHashable], ["day": "2026-11-13", "today": 1, "total": 6])
        let update = Data(#"{"type":"room_counter","counter":{"day":"2026-11-13","today":4,"total":9},"delta":-1,"eventID":"e","sender":{"id":"a","name":"小红"}}"#.utf8)
        let decoded = try? JSONDecoder().decode(RelayMessage.self, from: update)
        XCTAssertEqual(decoded?.counter, DailyCounter(day: "2026-11-13", today: 4, total: 9))
        XCTAssertEqual(decoded?.delta, -1)
        XCTAssertEqual(decoded?.sender?.name, "小红")
        let welcome = Data(#"{"type":"welcome","roomCounter":{"day":"2026-11-13","today":0,"total":3}}"#.utf8)
        XCTAssertEqual((try? JSONDecoder().decode(RelayMessage.self, from: welcome))?.roomCounter?.total, 3)
    }
    func testLANHelloCarriesCounter() {
        let room = LANProtocol.roomHash("9137")
        let counter = DailyCounter(day: "2026-11-13", today: 3, total: 30)
        let hello = LANProtocol.encode(.hello(id: "PEER", name: "阿杰", room: room, seq: 4, counter: counter))!
        let fields = (try? JSONSerialization.jsonObject(with: hello)) as? [String: Any] ?? [:]
        XCTAssertEqual(Set(fields.keys), ["v", "t", "id", "name", "room", "seq", "cd", "ct", "cn"])
        let message = LANProtocol.decode(hello, room: room, selfID: "SELF")
        XCTAssertEqual(message?.body, .hello)
        XCTAssertEqual(message?.counter, counter)
        // 1.9.x decoders (no cd/ct/cn properties) still read the hello.
        struct OldPacket: Decodable { let v: Int; let t: String; let id: String; let seq: Int }
        XCTAssertEqual((try? JSONDecoder().decode(OldPacket.self, from: hello))?.seq, 4)
        // A broken counter is dropped but the hello still counts for presence.
        var broken = LANPacket.hello(id: "PEER", name: "阿杰", room: room, seq: 5, counter: counter); broken.ct = 99
        let validated = LANProtocol.validate(broken, room: room, selfID: "SELF")
        XCTAssertEqual(validated?.body, .hello)
        XCTAssertEqual(validated?.counter, nil)
        var partial = LANPacket.hello(id: "PEER", name: "阿杰", room: room, seq: 6); partial.ct = 1
        XCTAssertEqual(LANProtocol.validate(partial, room: room, selfID: "SELF")?.counter, nil)
        // Late, out-of-order hellos cannot roll a friend's counter back.
        var book = LANCounterBook()
        let newer = DailyCounter(day: "2026-11-13", today: 4, total: 31)
        XCTAssertEqual(book.accept("PEER", seq: 8, counter: newer), true)
        XCTAssertEqual(book.accept("PEER", seq: 7, counter: counter), false)
        XCTAssertEqual(book.accept("PEER", seq: 8, counter: counter), false)
        XCTAssertEqual(book.counter(for: "PEER"), newer)
        book.forget("PEER")
        XCTAssertEqual(book.accept("PEER", seq: 1, counter: counter), true)
    }
}
