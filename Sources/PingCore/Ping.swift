import Foundation
import CoreGraphics

public enum PingKind: String, CaseIterable, Identifiable, Codable {
    case retreat, push, onMyWay, allIn, assist, needVision, missing, enemyVision, generic
    public var id: String { rawValue }
    public static let wheel: [PingKind] = [.retreat, .push, .onMyWay, .allIn, .assist, .needVision, .missing, .enemyVision]
    public var title: String {
        switch self {
        case .retreat: return "撤退"
        case .push: return "推进"
        case .onMyWay: return "正在路上"
        case .allIn: return "全力进攻"
        case .assist: return "请求协助"
        case .needVision: return "需要视野"
        case .missing: return "敌人消失"
        case .enemyVision: return "敌方视野"
        case .generic: return "普通信号"
        }
    }
    public var iconName: String {
        switch self {
        case .retreat: return "retreat"
        case .push: return "push"
        case .onMyWay: return "on_my_way_new"
        case .allIn: return "all_in"
        case .assist: return "assist"
        case .needVision: return "need_ward"
        case .missing: return "mia_new"
        case .enemyVision: return "area_is_warded_small_red_new"
        case .generic: return "ping"
        }
    }
    public var soundName: String {
        switch self {
        case .retreat: return "retreat"
        case .push: return "push"
        case .onMyWay: return "on_my_way"
        case .allIn: return "all_in"
        case .assist: return "assist_me"
        case .needVision: return "need_vision"
        case .missing: return "q_mark"
        case .enemyVision: return "enemy_vision"
        case .generic: return "alert"
        }
    }
}

public struct Modifiers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = Modifiers(rawValue: 1)
    public static let option = Modifiers(rawValue: 2)
    public static let command = Modifiers(rawValue: 4)
    public static let shift = Modifiers(rawValue: 8)
}

public struct TriggerChord: RawRepresentable, Hashable, Identifiable {
    public let modifiers: Modifiers
    public let keyCode: Int?
    public var id: String { rawValue }
    public static let controlOptionCommand = TriggerChord(modifiers: [.control, .option, .command])!
    public static let controlOptionShift = TriggerChord(modifiers: [.control, .option, .shift])!
    public static let controlCommandShift = TriggerChord(modifiers: [.control, .command, .shift])!
    public static let allCases = [controlOptionCommand, controlOptionShift, controlCommandShift]
    /// Only modifier combinations, or a modifier plus a supported physical key.
    /// Escape stays available to cancel a gesture.
    public init?(modifiers: Modifiers, keyCode: Int? = nil) {
        guard modifiers.rawValue > 0, modifiers.rawValue & ~15 == 0 else { return nil }
        if let keyCode {
            guard Self.availableKeys.contains(where: { $0.code == keyCode }) else { return nil }
        } else if modifiers.rawValue.nonzeroBitCount < 2 { return nil }
        self.modifiers = modifiers; self.keyCode = keyCode
    }
    public init?(rawValue: String) {
        switch rawValue {
        case "controlOptionCommand": self = .controlOptionCommand
        case "controlOptionShift": self = .controlOptionShift
        case "controlCommandShift": self = .controlCommandShift
        default:
            let fields = rawValue.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "v1", let bits = Int(fields[1]),
                  fields[2] == "-" || Int(fields[2]) != nil,
                  let chord = TriggerChord(modifiers: Modifiers(rawValue: bits), keyCode: Int(fields[2])) else { return nil }
            self = chord
        }
    }
    public var rawValue: String { "v1:\(modifiers.rawValue):\(keyCode.map(String.init) ?? "-")" }
    public var title: String { symbols }
    public var symbols: String {
        var parts: [String] = []
        for (modifier, symbol) in [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
            if modifiers.contains(modifier) { parts.append(symbol) }
        }
        if let keyCode, let key = Self.availableKeys.first(where: { $0.code == keyCode }) { parts.append(key.title) }
        return parts.joined(separator: "  ")
    }
    public static let availableKeys: [(code: Int, title: String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),
        (38,"J"),(40,"K"),(37,"L"),(46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),
        (15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
        (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),
        (49,"Space"),(48,"Tab"),(36,"Return"),(51,"Delete"),
        (27,"−"),(24,"="),(33,"["),(30,"]"),(42,"\\"),(41,";"),(39,"'"),(43,","),(47,"."),(44,"/"),(50,"`"),
        (123,"←"),(124,"→"),(125,"↓"),(126,"↑"),(115,"Home"),(119,"End"),(116,"Page Up"),(121,"Page Down"),
        (122,"F1"),(120,"F2"),(99,"F3"),(118,"F4"),(96,"F5"),(97,"F6"),(98,"F7"),(100,"F8"),
        (101,"F9"),(109,"F10"),(103,"F11"),(111,"F12"),(105,"F13"),(107,"F14"),(113,"F15"),
        (106,"F16"),(64,"F17"),(79,"F18"),(80,"F19"),(90,"F20")
    ]
}

public enum WheelGeometry {
    public static let centerRadius: CGFloat = 66
    public static let iconRadius: CGFloat = 101
    public static let outerRadius: CGFloat = 140

    /// Clockwise from north; nil in the ordinary Ping region.
    public static func direction(at point: CGPoint, center: CGPoint, deadZone: CGFloat) -> CGFloat? {
        let dx = point.x - center.x, dy = point.y - center.y
        guard hypot(dx, dy) > deadZone else { return nil }
        return atan2(dx, dy)
    }
    /// Coordinates use the AppKit convention: y increases upwards.
    public static func selection(at point: CGPoint, center: CGPoint, deadZone: CGFloat) -> PingKind {
        let dx = point.x - center.x, dy = point.y - center.y
        guard hypot(dx, dy) > deadZone else { return .generic }
        let clockwiseFromNorth = atan2(dx, dy)
        let index = Int(floor((clockwiseFromNorth + .pi / 8) / (.pi / 4)))
        return PingKind.wheel[(index % 8 + 8) % 8]
    }

    public static func clampedCenter(anchor: CGPoint, frame: CGRect, radius: CGFloat) -> CGPoint {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        return CGPoint(x: clamp(anchor.x, frame.minX + radius, frame.maxX - radius),
                       y: clamp(anchor.y, frame.minY + radius, frame.maxY - radius))
    }
}

public extension TriggerChord {
    func conflicts(with other: TriggerChord) -> Bool {
        self == other || (keyCode == nil && other.modifiers.isSuperset(of: modifiers)) ||
        (other.keyCode == nil && modifiers.isSuperset(of: other.modifiers))
    }
}
