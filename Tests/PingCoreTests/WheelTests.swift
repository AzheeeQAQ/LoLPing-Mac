import Foundation
import PingCore

final class WheelTests {
    func testMixedContentAndDirectionMapping() {
        let image = WheelContent.emote(String(repeating: "a", count: 64))
        var contents = WheelLayout.defaults
        XCTAssertEqual(contents.count, 9)
        for index in 0..<8 {
            let angle = Double(index)*(.pi/4)
            let point = CGPoint(x: 159+sin(angle)*110, y: 159-cos(angle)*110)
            XCTAssertEqual(WheelLayout.editorSlot(at: point, side: 318), index)
        }
        XCTAssertEqual(WheelLayout.editorSlot(at: CGPoint(x: 159, y: 159), side: 318), 8)
        XCTAssertEqual(WheelLayout.editorSlot(at: .zero, side: 318), nil)
        XCTAssertEqual(WheelLayout.editorSlot(at: CGPoint(x: CGFloat.infinity, y: 159), side: 318), nil)
        for (index, selector) in (PingKind.wheel+[.generic]).enumerated() {
            XCTAssertEqual(WheelLayout.index(for: selector), index)
            XCTAssertEqual(contents[index], .ping(selector))
        }
        contents[0] = image; contents[2] = .ping(.enemyVision); contents[8] = .empty
        XCTAssertEqual(contents[WheelLayout.index(for: .retreat)], image)
        XCTAssertEqual(contents[WheelLayout.index(for: .onMyWay)], .ping(.enemyVision))
        XCTAssertEqual(contents[WheelLayout.index(for: .generic)], .empty)
        let values = PingKind.allCases.map(WheelContent.ping)+[image, .empty]
        for value in values {
            XCTAssertEqual(WheelContent(rawValue: value.rawValue), value)
            XCTAssertEqual(try? JSONDecoder().decode(WheelContent.self, from: JSONEncoder().encode(value)), value)
        }
        for raw in ["", "retreat", "ping:unknown", "emote:../file", "emote:"+String(repeating: "G", count: 64), "emote:"+String(repeating: "a", count: 63)] {
            XCTAssertEqual(WheelContent(rawValue: raw), nil)
            let data = try! JSONEncoder().encode(raw)
            XCTAssertEqual(try? JSONDecoder().decode(WheelContent.self, from: data), nil)
        }
    }
}
