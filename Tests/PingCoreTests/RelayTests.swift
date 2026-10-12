import Foundation
import PingCore

final class RelayTests {
    func testEndpointAndRoom() {
        XCTAssertEqual(RelayProtocol.endpoint(" wss://ping.example.com ")?.absoluteString, "wss://ping.example.com/ws")
        XCTAssertEqual(RelayProtocol.endpoint("ws://127.0.0.1:8787")?.absoluteString, "ws://127.0.0.1:8787/ws")
        XCTAssertEqual(RelayProtocol.endpoint("ws://[::1]:8787/ws") != nil, true)
        for invalid in ["https://ping.example.com", "ws://ping.example.com/ws", "wss://user:pass@example.com/ws", "wss://example.com/ws?q=1", "wss://example.com/ws#fragment", "wss://example.com:0/ws"] {
            XCTAssertEqual(RelayProtocol.endpoint(invalid), nil)
        }
        XCTAssertEqual(RelayProtocol.roomCode(" abcd-efgh-jk23 "), "ABCDEFGHJK23")
        XCTAssertEqual(RelayProtocol.validRoomCode("ABCDEFGHJK23"), true)
        for invalid in ["", "ABC", "ABCDEFGHIJKL", "ABCDEFGHIJ01"] {
            XCTAssertEqual(RelayProtocol.validRoomCode(invalid), false)
        }
    }
    func testNameAndMessages() {
        XCTAssertEqual(RelayProtocol.displayName(" \n玩家\t "), "玩家")
        XCTAssertEqual(RelayProtocol.displayName("\n"), "玩家")
        XCTAssertEqual(RelayProtocol.displayName(String(repeating: "🐱", count: 30)).unicodeScalars.count, 24)
        for kind in PingKind.allCases {
            var message = RelayMessage(type: "ping")
            message.eventID = UUID().uuidString; message.kind = kind
            let data = try! JSONEncoder().encode(message)
            let decoded = try! JSONDecoder().decode(RelayMessage.self, from: data)
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertEqual(decoded.eventID, message.eventID)
        }
    }
}
