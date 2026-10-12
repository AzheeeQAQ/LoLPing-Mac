import Foundation
import CoreGraphics
import CryptoKit

/// Wire format and validation for 局域网互发. Pure logic only: sockets,
/// Bonjour and rendering live in the app target. Times passed in here are
/// local monotonic seconds; nothing compares clocks between machines.
public enum LANProtocol {
    public static let version = 1
    public static let maxPacketBytes = 1024
    public static let serviceType = "_lolping._udp"
    public static let maxNameLength = 16
    public static let maxRoomLength = 32
    public static let helloInterval: TimeInterval = 3
    public static let onlineWindow: TimeInterval = 10
    public static let maxPeers = 32
    public static let fallbackName = "队友"

    /// Removes control/format characters and line breaks, trims, and caps at 16
    /// characters. Zero-width joiners are kept so emoji sequences survive.
    public static func sanitizeName(_ raw: String) -> String {
        let banned = CharacterSet.controlCharacters.union(.newlines).subtracting(CharacterSet(charactersIn: "\u{200D}"))
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.filter { !banned.contains($0) })
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }
    /// Room codes are compared case-insensitively, so "ab12" and "AB12" meet.
    public static func normalizeRoomCode(_ raw: String) -> String {
        let banned = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.filter { !banned.contains($0) })
        return String(String(scalars).uppercased().prefix(maxRoomLength))
    }
    /// The raw room code never leaves the machine; peers compare this hash.
    public static func roomHash(_ code: String) -> String {
        let digest = SHA256.hash(data: Data(("lolping-room:" + normalizeRoomCode(code)).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    /// Bonjour names are limited to 63 UTF-8 bytes; the short id keeps two
    /// players with the same nickname distinct.
    public static func serviceName(nickname: String, instanceID: String) -> String {
        let suffix = "-" + String(instanceID.replacingOccurrences(of: "-", with: "").prefix(6))
        var name = ""
        for character in sanitizeName(nickname) {
            guard (name + String(character) + suffix).utf8.count <= 63 else { break }
            name.append(character)
        }
        return (name.isEmpty ? "LoLPing" : name) + suffix
    }

    public static func encode(_ packet: LANPacket) -> Data? {
        guard let data = try? JSONEncoder().encode(packet), data.count <= maxPacketBytes else { return nil }
        return data
    }
    public static func decode(_ data: Data, room: String, selfID: String) -> LANMessage? {
        guard data.count <= maxPacketBytes, let packet = try? JSONDecoder().decode(LANPacket.self, from: data) else { return nil }
        return validate(packet, room: room, selfID: selfID)
    }
    /// Anything unexpected is dropped rather than repaired, except the display
    /// name and coordinates, which are made safe to draw.
    public static func validate(_ packet: LANPacket, room: String, selfID: String) -> LANMessage? {
        guard packet.v == version, packet.room == room, !packet.id.isEmpty, packet.id.count <= 64, packet.id != selfID else { return nil }
        let cleaned = sanitizeName(packet.name)
        let name = cleaned.isEmpty ? fallbackName : cleaned
        switch packet.t {
        case .hello:
            return LANMessage(sender: packet.id, name: name, seq: packet.seq, body: .hello)
        case .ping:
            guard let raw = packet.kind, let kind = PingKind(rawValue: raw),
                  let nx = packet.nx, let ny = packet.ny, nx.isFinite, ny.isFinite else { return nil }
            return LANMessage(sender: packet.id, name: name, seq: packet.seq,
                              body: .ping(kind, CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))))
        }
    }
}

public struct LANPacket: Codable, Equatable {
    public enum Kind: String, Codable { case ping, hello }
    public var v: Int
    public var t: Kind
    public var id: String
    public var name: String
    public var room: String
    public var seq: Int
    public var kind: String?
    public var nx: Double?
    public var ny: Double?
    public init(v: Int = LANProtocol.version, t: Kind, id: String, name: String, room: String, seq: Int,
                kind: String? = nil, nx: Double? = nil, ny: Double? = nil) {
        self.v = v; self.t = t; self.id = id; self.name = name; self.room = room; self.seq = seq
        self.kind = kind; self.nx = nx; self.ny = ny
    }
    public static func hello(id: String, name: String, room: String, seq: Int) -> LANPacket {
        LANPacket(t: .hello, id: id, name: name, room: room, seq: seq)
    }
    public static func ping(_ kind: PingKind, at position: CGPoint, id: String, name: String, room: String, seq: Int) -> LANPacket {
        LANPacket(t: .ping, id: id, name: name, room: room, seq: seq, kind: kind.rawValue, nx: Double(position.x), ny: Double(position.y))
    }
}

/// A packet that passed validation. Ping positions are normalized to [0, 1].
public struct LANMessage: Equatable {
    public enum Body: Equatable { case hello, ping(PingKind, CGPoint) }
    public let sender: String
    public let name: String
    public let seq: Int
    public let body: Body
}

/// Inbound UDP flows, one per remote address and port. A flow belongs to the
/// first sender id seen on it, and ping order is checked per flow, so someone
/// who copies a friend's id from the Bonjour TXT record can neither rotate ids
/// on one socket nor poison the friend's sequence from another one. Instance
/// ids are per launch, so a plain monotonic check drops UDP duplicates and
/// late, out-of-order pings.
public struct LANFlowTracker<Flow: Hashable> {
    public enum Verdict: Equatable { case accept, otherSender, duplicate }
    private var flows: [Flow: (sender: String, lastPing: Int?)] = [:]
    public init() {}
    /// `pingSeq` is nil for hellos, which only bind the flow.
    public mutating func check(_ flow: Flow, sender: String, pingSeq: Int?) -> Verdict {
        guard let entry = flows[flow] else { flows[flow] = (sender, pingSeq); return .accept }
        guard entry.sender == sender else { return .otherSender }
        guard let seq = pingSeq else { return .accept }
        if let last = entry.lastPing, seq <= last { return .duplicate }
        flows[flow] = (sender, seq)
        return .accept
    }
    public mutating func forget(_ flow: Flow) { flows[flow] = nil }
    public mutating func removeAll() { flows.removeAll() }
}

/// A peer is online while hellos or pings keep arriving within the window. The
/// table is capped so made-up ids cannot grow it (or the status line) forever.
public struct LANPresence {
    public struct Peer: Equatable {
        public let id: String
        public var name: String
        public let firstSeen: TimeInterval
        public var lastSeen: TimeInterval
    }
    public let window: TimeInterval
    public let capacity: Int
    private var peers: [String: Peer] = [:]
    public init(window: TimeInterval = LANProtocol.onlineWindow, capacity: Int = LANProtocol.maxPeers) {
        self.window = window; self.capacity = capacity
    }

    /// Returns false, recording nothing, for a new id while the table is full;
    /// slots free up when prune() forgets expired peers.
    @discardableResult public mutating func saw(_ id: String, name: String, at now: TimeInterval) -> Bool {
        guard var peer = peers[id] else {
            guard peers.count < capacity else { return false }
            peers[id] = Peer(id: id, name: name, firstSeen: now, lastSeen: now)
            return true
        }
        peer.name = name; peer.lastSeen = max(peer.lastSeen, now)
        peers[id] = peer
        return true
    }
    /// Stable order: whoever showed up first is listed first.
    public func online(at now: TimeInterval) -> [Peer] {
        peers.values.filter { now-$0.lastSeen <= window }
            .sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) }
    }
    /// Forgets expired peers and returns their ids.
    @discardableResult public mutating func prune(at now: TimeInterval) -> [String] {
        let expired = peers.values.filter { now-$0.lastSeen > window }.map(\.id)
        expired.forEach { peers[$0] = nil }
        return expired
    }
    public mutating func removeAll() { peers.removeAll() }
}

/// Rolling one-second windows. Per sender, the first 3 pings play sound, up to 8
/// still animate silently, and anything beyond is dropped. Across all senders at
/// most 6 sounds and 16 pings get through, so made-up sender ids cannot flood
/// the screen. Dropped pings are not recorded, so a flood cannot extend its
/// own penalty.
public struct LANRateLimiter {
    public enum Decision: Equatable { case withSound, silent, drop }
    public let soundLimit: Int
    public let showLimit: Int
    public let totalSoundLimit: Int
    public let totalShowLimit: Int
    public let window: TimeInterval
    private var history: [String: [TimeInterval]] = [:]
    private var shown: [TimeInterval] = []
    private var sounded: [TimeInterval] = []
    public init(soundLimit: Int = 3, showLimit: Int = 8, totalSoundLimit: Int = 6, totalShowLimit: Int = 16, window: TimeInterval = 1) {
        self.soundLimit = soundLimit; self.showLimit = showLimit
        self.totalSoundLimit = totalSoundLimit; self.totalShowLimit = totalShowLimit; self.window = window
    }
    public mutating func admit(_ sender: String, at now: TimeInterval) -> Decision {
        var recent = (history[sender] ?? []).filter { now-$0 < window }
        shown.removeAll { now-$0 >= window }; sounded.removeAll { now-$0 >= window }
        guard recent.count < showLimit, shown.count < totalShowLimit else {
            history[sender] = recent.isEmpty ? nil : recent
            return .drop
        }
        recent.append(now); shown.append(now)
        history[sender] = recent
        guard recent.count <= soundLimit, sounded.count < totalSoundLimit else { return .silent }
        sounded.append(now)
        return .withSound
    }
    public mutating func forget(_ sender: String) { history[sender] = nil }
}

/// Screen-relative coordinates in the AppKit convention (y grows upwards).
public enum LANGeometry {
    /// Matches NSMouseInRect for unflipped coordinates: minX and maxY inclusive.
    public static func screenIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { point.x >= $0.minX && point.x < $0.maxX && point.y > $0.minY && point.y <= $0.maxY }
    }
    public static func normalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max((point.x-frame.minX)/frame.width, 0), 1),
                       y: min(max((point.y-frame.minY)/frame.height, 0), 1))
    }
    public static func denormalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX+point.x*frame.width, y: frame.minY+point.y*frame.height)
    }
    /// Moves an anchor as little as possible so that `content` (expressed
    /// relative to the anchor) stays inside `bounds`; centers it when the
    /// content is larger than the bounds.
    public static func clampedAnchor(_ anchor: CGPoint, content: CGRect, within bounds: CGRect) -> CGPoint {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        return CGPoint(x: clamp(anchor.x, bounds.minX-content.minX, bounds.maxX-content.maxX),
                       y: clamp(anchor.y, bounds.minY-content.minY, bounds.maxY-content.maxY))
    }
}
