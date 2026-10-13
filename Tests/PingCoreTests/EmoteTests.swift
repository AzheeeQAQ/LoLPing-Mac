import Foundation
import CoreGraphics
import PingCore

final class EmoteTests {
    func testBoundedReassembly() {
        var png = Data(repeating: 255, count: EmotePayload.maxBytes)
        png.replaceSubrange(0..<8, with: [137,80,78,71,13,10,26,10])
        png.replaceSubrange(12..<24, with: [73,72,68,82,0,0,0,160,0,0,0,160])
        let payload = EmotePayload(id: String(repeating: "a", count: 64), name: String(repeating: "🌟", count: 24), png: png)
        XCTAssertEqual(payload.isValid, true)
        let packets = LANEmoteChunk.packets(payload, room: LANProtocol.roomHash("9137"), sender: UUID().uuidString,
                                            name: String(repeating: "🌟", count: 16), at: CGPoint(x: 1, y: 0))
        XCTAssertEqual(packets.count, 103)
        XCTAssertEqual(packets.allSatisfy { $0.count <= 1024 }, true)
        var assembler = LANEmoteAssembler(), received = 0
        for packet in packets.reversed()+packets {
            let chunk = try! JSONDecoder().decode(LANEmoteChunk.self, from: packet)
            if let (result, point) = assembler.accept(chunk, at: 1) {
                XCTAssertEqual(result, payload); XCTAssertEqual(point, CGPoint(x: 1, y: 0)); received += 1
            }
        }
        XCTAssertEqual(received, 1)
        // Missing chunks never display, and an expired assembly cannot be completed by stale fragments.
        var missing = LANEmoteAssembler()
        let chunks = packets.map { try! JSONDecoder().decode(LANEmoteChunk.self, from: $0) }
        for chunk in chunks.dropLast() { XCTAssertEqual(missing.accept(chunk, at: 0) == nil, true) }
        XCTAssertEqual(missing.accept(chunks.last!, at: 6) == nil, true)
        XCTAssertEqual(EmotePayload(id: payload.id, name: "name", png: png+Data([0])).isValid, false)
        XCTAssertEqual(EmotePayload(id: "../../etc/passwd", name: "name", png: png).isValid, false)
        png.replaceSubrange(16..<20, with: [0,0,0,161])
        XCTAssertEqual(EmotePayload(id: payload.id, name: "name", png: png).isValid, false)
        XCTAssertEqual(TriggerChord.controlOptionCommand.conflicts(with: .controlOptionShift), false)
    }
}
