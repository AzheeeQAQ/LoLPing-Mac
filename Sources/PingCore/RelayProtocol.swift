import Foundation
import CoreGraphics

public struct RelayPosition: Codable, Equatable {
    public let nx: Double
    public let ny: Double
    public init(nx: Double, ny: Double) { self.nx = nx; self.ny = ny }
    public init(_ point: CGPoint) { nx = point.x; ny = point.y }
    public var isValid: Bool { nx.isFinite && ny.isFinite && (0...1).contains(nx) && (0...1).contains(ny) }
    public var point: CGPoint { CGPoint(x: nx, y: ny) }
}

public enum RelayProtocol {
    public static let version = 1
    public static let maxMessageBytes = 49_152

    public static func displayName(_ input: String) -> String {
        let normalized = input.precomposedStringWithCanonicalMapping
        let scalars = normalized.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(scalars.prefix(24))).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "玩家" : value
    }

    public static func roomCode(_ input: String) -> String {
        input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }
    public static func validRoomCode(_ input: String) -> Bool {
        input.count == 12 && input.allSatisfy { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) }
    }
    public static func endpoint(_ input: String) -> URL? {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme == "wss" || (parts.scheme == "ws" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else { return nil }
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/ws" }
        return parts.url
    }
}

public struct RelayPeer: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
}

public struct RelayMessage: Codable {
    public var type: String
    public var version: Int?
    public var action: String?
    public var room: String?
    public var name: String?
    public var token: String?
    public var memberID: String?
    public var peers: [RelayPeer]?
    public var eventID: String?
    public var kind: PingKind?
    public var capabilities: [String]?
    public var emote: EmotePayload?
    public var position: RelayPosition?
    public var sender: RelayPeer?
    public var code: String?
    public var message: String?
    public init(type: String) { self.type = type }
}
