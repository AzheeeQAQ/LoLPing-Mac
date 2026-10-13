import Foundation
import CoreGraphics

/// Still images cross the network in a single relay frame or small LAN datagrams.
public struct EmotePayload: Codable, Equatable {
    public static let maxBytes = 32_768
    public static let maxSide = 160
    public let id: String
    public let name: String
    public let png: Data
    public init(id: String, name: String, png: Data) { self.id = id; self.name = name; self.png = png }
    public var isValid: Bool {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
              !name.isEmpty, name.unicodeScalars.count <= 24,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              png.count >= 33, png.count <= Self.maxBytes,
              Array(png.prefix(8)) == [137,80,78,71,13,10,26,10],
              Array(png[12..<16]) == [73,72,68,82] else { return false }
        func dimension(_ offset: Int) -> UInt32 { png[offset..<offset+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        return (1...UInt32(Self.maxSide)).contains(dimension(16)) && (1...UInt32(Self.maxSide)).contains(dimension(20))
    }
}

public struct LANEmoteChunk: Codable {
    public let t: String
    public let room: String
    public let sender: String
    public let name: String
    public let eventID: String
    public let assetID: String
    public let title: String
    public let index: Int
    public let total: Int
    public let bytes: Data
    public let nx: Double
    public let ny: Double
    public static func packets(_ emote: EmotePayload, room: String, sender: String, name: String, at point: CGPoint) -> [Data] {
        guard emote.isValid else { return [] }
        let event = UUID().uuidString, size = 320, total = (emote.png.count+size-1)/size
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let packets = (0..<total).compactMap { index -> Data? in
            let chunk = Self(t: "emote", room: room, sender: sender, name: name, eventID: event, assetID: emote.id,
                             title: emote.name, index: index, total: total,
                             bytes: emote.png.subdata(in: index*size..<min((index+1)*size, emote.png.count)), nx: point.x, ny: point.y)
            guard let data = try? encoder.encode(chunk), data.count <= 1024 else { return nil }
            return data
        }
        return packets.count == total ? packets : []
    }
}

/// Bounded, out-of-order reassembly. Incomplete images expire; retries never replay an effect.
public struct LANEmoteAssembler {
    private struct Pending { let first: LANEmoteChunk; let started: TimeInterval; var parts: [Int: Data] }
    private var pending: [String: Pending] = [:]
    private var completed: [(String, TimeInterval)] = []
    public init() {}
    public mutating func accept(_ c: LANEmoteChunk, at now: TimeInterval) -> (EmotePayload, CGPoint)? {
        pending = pending.filter { now-$0.value.started < 5 }
        completed.removeAll { now-$0.1 > 10 }
        guard c.t == "emote", UUID(uuidString: c.eventID) != nil, UUID(uuidString: c.sender) != nil,
              c.name.count <= 16, c.title.unicodeScalars.count <= 24,
              c.total > 0, c.total <= 103, c.index >= 0, c.index < c.total,
              !c.bytes.isEmpty, c.bytes.count <= 320, c.nx.isFinite, c.ny.isFinite,
              (0...1).contains(c.nx), (0...1).contains(c.ny) else { return nil }
        let key = c.sender+":"+c.eventID.lowercased()
        guard !completed.contains(where: { $0.0 == key }) else { return nil }
        if pending[key] == nil {
            guard pending.count < 32, pending.values.filter({ $0.first.sender == c.sender }).count < 2 else { return nil }
            pending[key] = Pending(first: c, started: now, parts: [:])
        }
        guard var p = pending[key], p.first.assetID == c.assetID, p.first.title == c.title,
              p.first.name == c.name, p.first.room == c.room, p.first.total == c.total,
              p.first.nx == c.nx, p.first.ny == c.ny else { return nil }
        p.parts[c.index] = c.bytes; pending[key] = p
        guard p.parts.count == c.total else { return nil }
        pending[key] = nil
        var data = Data(); for index in 0..<c.total { data.append(p.parts[index]!) }
        let emote = EmotePayload(id: c.assetID, name: c.title, png: data)
        guard emote.isValid else { return nil }
        completed.append((key, now)); if completed.count > 128 { completed.removeFirst() }
        return (emote, CGPoint(x: c.nx, y: c.ny))
    }
}
