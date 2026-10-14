import Foundation
import CoreGraphics
import PingCore

final class LANTests {
    let room = LANProtocol.roomHash("9137")
    let me = "SELF-INSTANCE"

    func ping(v: Int = 1, id: String = "PEER", name: String = "阿杰", room: String? = nil, seq: Int = 1,
              kind: String? = "retreat", nx: Double? = 0.25, ny: Double? = 0.75) -> LANPacket {
        LANPacket(v: v, t: .ping, id: id, name: name, room: room ?? self.room, seq: seq, kind: kind, nx: nx, ny: ny)
    }
    func json(_ body: String) -> Data { Data(body.utf8) }

    func testRoomHashAndNormalization() {
        // printf 'lolping-room:9137' | shasum -a 256 | cut -c1-16
        XCTAssertEqual(LANProtocol.roomHash("9137"), "713f8bfc147979f3")
        XCTAssertEqual(LANProtocol.roomHash("ABCD"), "f535c1e9bec8e5c4")
        XCTAssertEqual(LANProtocol.roomHash(" ab cd\n"), LANProtocol.roomHash("ABCD"))
        XCTAssertEqual(LANProtocol.normalizeRoomCode(" 91\t37 "), "9137")
        XCTAssertEqual(LANProtocol.roomHash("9137") == LANProtocol.roomHash("0000"), false)
        XCTAssertEqual(LANProtocol.normalizeRoomCode(String(repeating: "7", count: 40)).count, LANProtocol.maxRoomLength)
    }
    func testPacketRoundTrip() {
        let packet = LANPacket.ping(.retreat, at: CGPoint(x: 0.25, y: 0.75), id: "PEER", name: "阿杰", room: room, seq: 7)
        guard let data = LANProtocol.encode(packet) else { XCTAssertEqual("encode", "nil"); return }
        XCTAssertEqual(try? JSONDecoder().decode(LANPacket.self, from: data), packet)
        let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        XCTAssertEqual(Set(fields.keys), ["v", "t", "id", "name", "room", "seq", "kind", "nx", "ny"])
        XCTAssertEqual(fields["t"] as? String, "ping")
        let message = LANProtocol.decode(data, room: room, selfID: me)
        XCTAssertEqual(message?.sender, "PEER")
        XCTAssertEqual(message?.name, "阿杰")
        XCTAssertEqual(message?.seq, 7)
        XCTAssertEqual(message?.body, .ping(.retreat, CGPoint(x: 0.25, y: 0.75)))
        let hello = LANProtocol.encode(.hello(id: "PEER", name: "阿杰", room: room, seq: 8))!
        let helloFields = (try? JSONSerialization.jsonObject(with: hello)) as? [String: Any] ?? [:]
        XCTAssertEqual(Set(helloFields.keys), ["v", "t", "id", "name", "room", "seq"])
        XCTAssertEqual(LANProtocol.decode(hello, room: room, selfID: me)?.body, .hello)
        // Every kind survives the trip by raw value.
        for kind in PingKind.allCases {
            let data = LANProtocol.encode(.ping(kind, at: CGPoint(x: 0.5, y: 0.5), id: "PEER", name: "x", room: room, seq: 1))!
            XCTAssertEqual(LANProtocol.decode(data, room: room, selfID: me)?.body, .ping(kind, CGPoint(x: 0.5, y: 0.5)))
        }
    }
    func testRejectsInvalidPackets() {
        func accepted(_ packet: LANPacket) -> Bool { LANProtocol.validate(packet, room: room, selfID: me) != nil }
        XCTAssertEqual(accepted(ping()), true)
        XCTAssertEqual(accepted(ping(v: 2)), false)
        XCTAssertEqual(accepted(ping(room: LANProtocol.roomHash("0000"))), false)
        XCTAssertEqual(accepted(ping(id: me)), false)
        XCTAssertEqual(accepted(ping(id: "")), false)
        XCTAssertEqual(accepted(ping(id: String(repeating: "x", count: 65))), false)
        XCTAssertEqual(accepted(ping(kind: "danger")), false)
        XCTAssertEqual(accepted(ping(kind: nil)), false)
        XCTAssertEqual(accepted(ping(nx: nil)), false)
        XCTAssertEqual(accepted(ping(nx: .nan)), false)
        XCTAssertEqual(accepted(ping(ny: .infinity)), false)
        XCTAssertEqual(accepted(ping(ny: -.infinity)), false)
        // Out-of-range but finite positions are clamped onto the screen.
        XCTAssertEqual(LANProtocol.validate(ping(nx: 1.7, ny: -3), room: room, selfID: me)?.body, .ping(.retreat, CGPoint(x: 1, y: 0)))
        // Raw bytes: non-JSON NaN, unknown type, garbage and oversized datagrams.
        let base = "\"v\":1,\"id\":\"PEER\",\"name\":\"n\",\"room\":\"\(room)\",\"seq\":1"
        XCTAssertEqual(LANProtocol.decode(json("{\(base),\"t\":\"ping\",\"kind\":\"retreat\",\"nx\":0.5,\"ny\":0.5}"), room: room, selfID: me) != nil, true)
        XCTAssertEqual(LANProtocol.decode(json("{\(base),\"t\":\"ping\",\"kind\":\"retreat\",\"nx\":NaN,\"ny\":0.5}"), room: room, selfID: me) == nil, true)
        XCTAssertEqual(LANProtocol.decode(json("{\(base),\"t\":\"bye\"}"), room: room, selfID: me) == nil, true)
        XCTAssertEqual(LANProtocol.decode(json("{\(base),\"t\":\"ping\",\"kind\":\"retreat\",\"nx\":\"0.5\",\"ny\":0.5}"), room: room, selfID: me) == nil, true)
        XCTAssertEqual(LANProtocol.decode(Data([0xff, 0x00, 0x7b]), room: room, selfID: me) == nil, true)
        let padding = String(repeating: " ", count: 1100)
        let oversized = json("{\(base),\"t\":\"hello\"}\(padding)")
        XCTAssertEqual(oversized.count > LANProtocol.maxPacketBytes, true)
        XCTAssertEqual(LANProtocol.decode(oversized, room: room, selfID: me) == nil, true)
        XCTAssertEqual(LANProtocol.encode(ping(name: String(repeating: "长", count: 400))) == nil, true)
    }
    func testNameSanitizing() {
        XCTAssertEqual(LANProtocol.sanitizeName("  阿杰\n\u{0007}  "), "阿杰")
        XCTAssertEqual(LANProtocol.sanitizeName("\u{202E}evil\u{0000}"), "evil")
        XCTAssertEqual(LANProtocol.sanitizeName("小\r\n王"), "小王")
        XCTAssertEqual(LANProtocol.sanitizeName(String(repeating: "名", count: 20)), String(repeating: "名", count: 16))
        XCTAssertEqual(LANProtocol.sanitizeName("123456789012345 7"), "123456789012345")
        XCTAssertEqual(LANProtocol.sanitizeName("👨‍👩‍👧"), "👨‍👩‍👧")
        let long = LANProtocol.validate(ping(name: "  \u{0001}" + String(repeating: "a", count: 40)), room: room, selfID: me)
        XCTAssertEqual(long?.name, String(repeating: "a", count: 16))
        XCTAssertEqual(LANProtocol.validate(ping(name: "\u{0007}\n "), room: room, selfID: me)?.name, LANProtocol.fallbackName)
        let service = LANProtocol.serviceName(nickname: String(repeating: "😀", count: 16), instanceID: "12345678-ABCD")
        XCTAssertEqual(service.utf8.count <= 63, true)
        XCTAssertEqual(service.hasSuffix("-123456"), true)
        XCTAssertEqual(LANProtocol.serviceName(nickname: "阿杰", instanceID: "ABCDEF12-0000"), "阿杰-ABCDEF")
        XCTAssertEqual(LANProtocol.serviceName(nickname: "\n", instanceID: "ABCDEF12-0000"), "LoLPing-ABCDEF")
    }
    func testSequenceDedupe() {
        var flows = LANFlowTracker<Int>()
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 1), .accept)
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 1), .duplicate)
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 0), .duplicate)
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 2), .accept)
        XCTAssertEqual(flows.check(2, sender: "b", pingSeq: 1), .accept)
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 5), .accept)
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 3), .duplicate)
        // Hellos share the sequence counter but only bind the flow.
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: nil), .accept)
        XCTAssertEqual(flows.check(3, sender: "c", pingSeq: nil), .accept)
        XCTAssertEqual(flows.check(3, sender: "c", pingSeq: 9), .accept)
        // One socket cannot rotate ids to dodge per-sender limits.
        XCTAssertEqual(flows.check(1, sender: "spoof", pingSeq: 6), .otherSender)
        XCTAssertEqual(flows.check(1, sender: "spoof", pingSeq: nil), .otherSender)
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 6), .accept)
        // A stranger copying "a" (public in TXT) from another socket cannot
        // poison the real flow with a huge sequence number.
        XCTAssertEqual(flows.check(4, sender: "a", pingSeq: Int.max), .accept)
        XCTAssertEqual(flows.check(1, sender: "a", pingSeq: 7), .accept)
        // A peer that dials again gets a new flow with a fresh sequence.
        flows.forget(1)
        XCTAssertEqual(flows.check(1, sender: "z", pingSeq: 1), .accept)
        flows.removeAll()
        XCTAssertEqual(flows.check(3, sender: "y", pingSeq: 1), .accept)
    }
    func testPresence() {
        var presence = LANPresence()
        presence.saw("a", name: "阿杰", at: 100)
        presence.saw("b", name: "小王", at: 101)
        XCTAssertEqual(presence.online(at: 105).map(\.name), ["阿杰", "小王"])
        XCTAssertEqual(presence.online(at: 110).map(\.name), ["阿杰", "小王"])
        XCTAssertEqual(presence.online(at: 110.5).map(\.name), ["小王"])
        presence.saw("a", name: "阿杰2", at: 111)
        XCTAssertEqual(presence.online(at: 111).map(\.name), ["阿杰2", "小王"])
        XCTAssertEqual(presence.prune(at: 115).sorted(), ["b"])
        XCTAssertEqual(presence.prune(at: 130).sorted(), ["a"])
        XCTAssertEqual(presence.online(at: 130).isEmpty, true)
        // Made-up ids cannot grow the table past its capacity.
        var capped = LANPresence(capacity: 2)
        XCTAssertEqual(capped.saw("a", name: "阿杰", at: 0), true)
        XCTAssertEqual(capped.saw("b", name: "小王", at: 0), true)
        XCTAssertEqual(capped.saw("c", name: "spam", at: 1), false)
        XCTAssertEqual(capped.saw("a", name: "阿杰", at: 1), true)
        XCTAssertEqual(capped.online(at: 1).map(\.name), ["阿杰", "小王"])
        XCTAssertEqual(capped.prune(at: 10.5), ["b"])
        XCTAssertEqual(capped.saw("c", name: "小李", at: 10.5), true)
        XCTAssertEqual(capped.online(at: 10.5).map(\.name), ["阿杰", "小李"])
        XCTAssertEqual(LANPresence().capacity, 32)
    }
    func testRateLimiter() {
        var limiter = LANRateLimiter()
        let burst = (0..<10).map { limiter.admit("a", at: Double($0)*0.05) }
        XCTAssertEqual(burst, [.withSound, .withSound, .withSound, .silent, .silent, .silent, .silent, .silent, .drop, .drop])
        XCTAssertEqual(limiter.admit("b", at: 0.45), .withSound)
        // At 1.02 s only the ping from 0.00 has left the rolling window.
        XCTAssertEqual(limiter.admit("a", at: 1.02), .silent)
        XCTAssertEqual(limiter.admit("a", at: 1.03), .drop)
        XCTAssertEqual(limiter.admit("a", at: 1.5), .withSound)
        XCTAssertEqual(limiter.admit("a", at: 3), .withSound)
        // Rotating sender ids: at most 6 sounds and 16 pings per second overall.
        var total = LANRateLimiter()
        let spam = (0..<20).map { total.admit("spam-\($0)", at: 10+Double($0)*0.01) }
        XCTAssertEqual(spam.filter { $0 == .withSound }.count, 6)
        XCTAssertEqual(spam.filter { $0 == .silent }.count, 10)
        XCTAssertEqual(Array(spam.prefix(6)), Array(repeating: .withSound, count: 6))
        XCTAssertEqual(Array(spam.suffix(4)), Array(repeating: .drop, count: 4))
        XCTAssertEqual(total.admit("friend", at: 10.5), .drop)
        // Once the window has passed, everyone gets sound again.
        XCTAssertEqual(total.admit("friend", at: 11.2), .withSound)
        XCTAssertEqual(total.admit("spam-0", at: 11.2), .withSound)
    }
    func testCoordinates() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let top = CGRect(x: 0, y: 900, width: 2560, height: 1440)
        let frames = [main, left, top]
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: 100, y: 100), in: frames), 0)
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: -960, y: 360), in: frames), 1)
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: 100, y: 1000), in: frames), 2)
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: 0, y: 900), in: frames), 0)
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: -0.5, y: 500), in: frames), 1)
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: 5000, y: 5000), in: frames), nil)
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: -960, y: frames[1].minY), in: frames), 1)
        XCTAssertEqual(LANGeometry.screenIndex(containing: CGPoint(x: frames[1].minX, y: frames[1].minY), in: frames), 1)
        XCTAssertEqual(LANGeometry.normalize(CGPoint(x: -960, y: 360), in: left), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(LANGeometry.normalize(CGPoint(x: 0, y: 0), in: main), CGPoint(x: 0, y: 0))
        XCTAssertEqual(LANGeometry.normalize(CGPoint(x: 1440, y: 900), in: main), CGPoint(x: 1, y: 1))
        XCTAssertEqual(LANGeometry.normalize(CGPoint(x: -10, y: 950), in: main), CGPoint(x: 0, y: 1))
        XCTAssertEqual(LANGeometry.normalize(CGPoint(x: 3, y: 3), in: .zero), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(LANGeometry.denormalize(CGPoint(x: 0.25, y: 0.75), in: left), CGPoint(x: -1440, y: 630))
        // Sender on the left display, receiver's mouse on the display above.
        let relative = LANGeometry.normalize(CGPoint(x: -1440, y: 630), in: left)
        XCTAssertEqual(relative, CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(LANGeometry.denormalize(relative, in: top), CGPoint(x: 640, y: 1980))
        // Visible ping content around the anchor at scale 1: ripple ±60, icon
        // up to +66, nickname down to -50. Only that is kept on the screen.
        let content = CGRect(x: -60, y: -50, width: 120, height: 116)
        XCTAssertEqual(LANGeometry.clampedAnchor(CGPoint(x: 0, y: 0), content: content, within: main), CGPoint(x: 60, y: 50))
        XCTAssertEqual(LANGeometry.clampedAnchor(CGPoint(x: 720, y: 450), content: content, within: main), CGPoint(x: 720, y: 450))
        // Top-right corner ping (0.97, 0.98) moves 17 pt left and 48 pt down,
        // not 67 and 130 as clamping the whole 220 pt panel to visibleFrame did.
        let corner = LANGeometry.denormalize(CGPoint(x: 0.97, y: 0.98), in: main)
        XCTAssertEqual(LANGeometry.clampedAnchor(corner, content: content, within: main), CGPoint(x: 1380, y: 834))
        let nearEdge = LANGeometry.denormalize(CGPoint(x: 0.05, y: 0.05), in: main)
        XCTAssertEqual(LANGeometry.clampedAnchor(nearEdge, content: content, within: main), CGPoint(x: 72, y: 50))
        XCTAssertEqual(LANGeometry.clampedAnchor(CGPoint(x: -1920, y: 900), content: content, within: left), CGPoint(x: -1860, y: 834))
        XCTAssertEqual(LANGeometry.clampedAnchor(CGPoint(x: -1, y: -180), content: content, within: left), CGPoint(x: -60, y: -130))
        XCTAssertEqual(LANGeometry.clampedAnchor(CGPoint(x: 900, y: 900), content: content, within: CGRect(x: 0, y: 0, width: 100, height: 100)), CGPoint(x: 50, y: 42))
    }
}
