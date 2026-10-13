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
    public static let function = Modifiers(rawValue: 16)
    public static let capsLock = Modifiers(rawValue: 32)
    public static let standard: Modifiers = [.control, .option, .command, .shift]
    public static let physicalSpecial: Modifiers = [.function, .capsLock]
}

public struct TriggerChord: RawRepresentable, Hashable, Identifiable {
    public let modifiers: Modifiers
    public let keyCodes: Set<Int>
    public var keyCode: Int? { keyCodes.sorted().first }
    public var id: String { rawValue }
    public static let controlOptionCommand = TriggerChord(modifiers: [.control, .option, .command])!
    public static let controlOptionShift = TriggerChord(modifiers: [.control, .option, .shift])!
    public static let controlCommandShift = TriggerChord(modifiers: [.control, .command, .shift])!
    public static let allCases = [controlOptionCommand, controlOptionShift, controlCommandShift]
    public init?(modifiers: Modifiers, keyCode: Int? = nil) {
        self.init(modifiers: modifiers, keyCodes: keyCode.map { [$0] } ?? [])
    }
    public init?(modifiers: Modifiers, keyCodes: Set<Int>) {
        guard modifiers.rawValue >= 0, modifiers.rawValue & ~63 == 0,
              !modifiers.isEmpty || !keyCodes.isEmpty,
              keyCodes.count <= 64, keyCodes.allSatisfy(Self.isRecordableKey) else { return nil }
        self.modifiers = modifiers; self.keyCodes = keyCodes
    }
    public static func isRecordableKey(_ code: Int) -> Bool {
        (0...65791).contains(code) && ![54,55,56,57,58,59,60,61,62,63].contains(code)
    }
    public init?(rawValue: String) {
        switch rawValue {
        case "controlOptionCommand": self = .controlOptionCommand
        case "controlOptionShift": self = .controlOptionShift
        case "controlCommandShift": self = .controlCommandShift
        default:
            let fields = rawValue.split(separator: ":", omittingEmptySubsequences: false)
            guard rawValue.count <= 512, fields.count == 3, ["v1", "v2"].contains(fields[0]), let bits = Int(fields[1]) else { return nil }
            let codes: [Int]
            if fields[2] == "-" { codes = [] }
            else {
                let keys = fields[2].split(separator: ",", omittingEmptySubsequences: false)
                codes = keys.compactMap { Int($0) }
                guard codes.count == keys.count, fields[0] != "v1" || codes.count == 1 else { return nil }
            }
            guard let chord = TriggerChord(modifiers: Modifiers(rawValue: bits), keyCodes: Set(codes)) else { return nil }
            self = chord
        }
    }
    public var rawValue: String {
        let version = keyCodes.count <= 1 && modifiers.rawValue <= 15 ? "v1" : "v2"
        return "\(version):\(modifiers.rawValue):\(keyCodes.isEmpty ? "-" : keyCodes.sorted().map(String.init).joined(separator: ","))"
    }
    public var title: String { symbols }
    public var symbols: String {
        var parts: [String] = []
        for (modifier, symbol) in [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "Fn"), (.capsLock, "Caps Lock")] {
            if modifiers.contains(modifier) { parts.append(symbol) }
        }
        parts += keyCodes.sorted().map(Self.keyTitle)
        return parts.joined(separator: "  ")
    }
    public static let availableKeys: [(code: Int, title: String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),
        (38,"J"),(40,"K"),(37,"L"),(46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),
        (15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
        (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),
        (49,"Space"),(48,"Tab"),(36,"Return"),(51,"Delete"),(53,"Esc"),(117,"Forward Delete"),
        (65,"小键盘 ."),(67,"小键盘 ×"),(69,"小键盘 +"),(71,"Clear"),(75,"小键盘 /"),(76,"小键盘 Enter"),(78,"小键盘 −"),(81,"小键盘 ="),
        (82,"小键盘 0"),(83,"小键盘 1"),(84,"小键盘 2"),(85,"小键盘 3"),(86,"小键盘 4"),(87,"小键盘 5"),(88,"小键盘 6"),(89,"小键盘 7"),(91,"小键盘 8"),(92,"小键盘 9"),
        (93,"¥"),(94,"_"),(95,"小键盘 ,"),(102,"英数"),(104,"かな"),(110,"菜单"),(114,"Help"),
        (27,"−"),(24,"="),(33,"["),(30,"]"),(42,"\\"),(41,";"),(39,"'"),(43,","),(47,"."),(44,"/"),(50,"`"),
        (123,"←"),(124,"→"),(125,"↓"),(126,"↑"),(115,"Home"),(119,"End"),(116,"Page Up"),(121,"Page Down"),
        (122,"F1"),(120,"F2"),(99,"F3"),(118,"F4"),(96,"F5"),(97,"F6"),(98,"F7"),(100,"F8"),
        (101,"F9"),(109,"F10"),(103,"F11"),(111,"F12"),(105,"F13"),(107,"F14"),(113,"F15"),
        (106,"F16"),(64,"F17"),(79,"F18"),(80,"F19"),(90,"F20")
    ]
    public static func keyTitle(_ code: Int) -> String {
        if let key = availableKeys.first(where: { $0.code == code }) { return key.title }
        if code >= 65536 {
            return [0:"音量＋",1:"音量−",2:"亮度＋",3:"亮度−",7:"静音",16:"播放 / 暂停",17:"下一首",18:"上一首",19:"快进",20:"快退",21:"键盘亮度＋",22:"键盘亮度−"][code-65536] ?? "媒体键 \(code-65536)"
        }
        return "按键 \(code)"
    }
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
        (other.modifiers.isSuperset(of: modifiers) && other.keyCodes.isSuperset(of: keyCodes)) ||
        (modifiers.isSuperset(of: other.modifiers) && keyCodes.isSuperset(of: other.keyCodes))
    }
}
