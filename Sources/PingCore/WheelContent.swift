import Foundation

/// Slot content is independent of its compass position. One wheel can mix
/// protocol pings, image payloads and empty slots without changing gestures.
public enum WheelContent: Hashable, Codable, RawRepresentable, Identifiable {
    case ping(PingKind)
    case emote(String)
    case empty
    public var id: String { rawValue }
    public var rawValue: String {
        switch self {
        case .ping(let kind): return "ping:"+kind.rawValue
        case .emote(let id): return "emote:"+id
        case .empty: return "empty"
        }
    }
    public init?(rawValue: String) {
        if rawValue == "empty" { self = .empty }
        else if rawValue.hasPrefix("ping:"), let kind = PingKind(rawValue: String(rawValue.dropFirst(5))) { self = .ping(kind) }
        else if rawValue.hasPrefix("emote:") {
            let id = String(rawValue.dropFirst(6))
            guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            self = .emote(id)
        } else { return nil }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid wheel content") }
        self = value
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

public enum WheelLayout {
    public static let defaults: [WheelContent] = PingKind.wheel.map(WheelContent.ping)+[.ping(.generic)]
    public static let positions = ["↑ 上", "↗ 右上", "→ 右", "↘ 右下", "↓ 下", "↙ 左下", "← 左", "↖ 左上", "中心"]
    public static func index(for selection: PingKind) -> Int { PingKind.wheel.firstIndex(of: selection) ?? 8 }
    /// Route a top-left editor drop location once, avoiding overlapping sector rectangles.
    public static func editorSlot(at point: CGPoint, side: CGFloat) -> Int? {
        guard side > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let x = point.x-side/2, y = point.y-side/2
        let radius = hypot(x, y)
        guard radius <= side*0.48 else { return nil }
        if radius <= side*0.22 { return 8 }
        let clockwise = atan2(x, -y)
        return (Int(floor((clockwise + .pi/8)/(.pi/4)))+8)%8
    }
}
