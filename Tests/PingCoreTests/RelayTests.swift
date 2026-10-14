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
    func testRelativePositionsAcrossDisplays() {
        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                      CGRect(x: -2560, y: -300, width: 2560, height: 1440),
                      CGRect(x: 0, y: 1080, width: 1440, height: 900)]
        for source in frames {
            for destination in frames {
                for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.8), CGPoint(x: 0.25, y: 0.75)] {
                    let anchor = LANGeometry.denormalize(point, in: source)
                    let relative = RelayPosition(LANGeometry.normalize(anchor, in: source))
                    XCTAssertEqual(relative.isValid, true)
                    var message = RelayMessage(type: "ping"); message.position = relative
                    let decoded = try! JSONDecoder().decode(RelayMessage.self, from: JSONEncoder().encode(message))
                    XCTAssertEqual(decoded.position, relative)
                    let receiver = LANGeometry.denormalize(decoded.position!.point, in: destination)
                    let normalizedAgain = LANGeometry.normalize(receiver, in: destination)
                    XCTAssertEqual(abs(normalizedAgain.x-point.x) < 0.00001, true)
                    XCTAssertEqual(abs(normalizedAgain.y-point.y) < 0.00001, true)
                }
            }
        }
        for point in [RelayPosition(nx: -0.1, ny: 0.5), RelayPosition(nx: 0.5, ny: 1.1), RelayPosition(nx: .nan, ny: 0.5), RelayPosition(nx: 0.5, ny: .infinity)] {
            XCTAssertEqual(point.isValid, false)
        }
        XCTAssertEqual(try! JSONDecoder().decode(RelayMessage.self, from: Data("{\"type\":\"ping\"}".utf8)).position, nil)
    }

}
