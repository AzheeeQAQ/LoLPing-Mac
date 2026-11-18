import Foundation

/// 当日 / 总计计数。“一天”固定按 UTC+8 划分，与本机时区无关。
/// 也用作服务器联机与局域网联机里同步给朋友的快照。
public struct DailyCounter: Codable, Equatable {
    public static let timeZone = TimeZone(secondsFromGMT: 8*3600)!
    /// 与中继服务端校验一致；超出范围的快照视为无效。
    public static let maxValue = 1_000_000_000
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    public private(set) var day: String
    public private(set) var today: Int
    public private(set) var total: Int

    public init(day: String, today: Int, total: Int) {
        self.day = day
        self.today = min(max(today, 0), Self.maxValue)
        self.total = min(max(total, self.today), Self.maxValue)
    }
    /// 来自网络的快照：格式或范围不对就整体丢弃，不做修补。
    public static func received(day: String?, today: Int?, total: Int?) -> DailyCounter? {
        guard let day, let today, let total, validDay(day),
              (0...maxValue).contains(today), (today...maxValue).contains(total) else { return nil }
        return DailyCounter(day: day, today: today, total: total)
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let counter = Self.received(day: try values.decode(String.self, forKey: .day),
                                          today: try values.decode(Int.self, forKey: .today),
                                          total: try values.decode(Int.self, forKey: .total)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid counter"))
        }
        self = counter
    }
    public static func validDay(_ value: String) -> Bool {
        value.utf8.count == 10 && value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// UTC+8 下的日期，例如 "2026-11-12"。
    public static func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// `date` 所在 UTC+8 日期往前数 `offset` 天，例如 1 = 昨天。
    public static func dayKey(daysBefore offset: Int, from date: Date) -> String {
        let start = calendar.startOfDay(for: date)
        return dayKey(for: calendar.date(byAdding: .day, value: -offset, to: start) ?? start.addingTimeInterval(-Double(offset)*86_400))
    }
    /// 严格晚于 `date` 的下一个 UTC+8 零点。
    public static func nextReset(after date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }
    /// 朋友的快照若停在前一天，今日按 0 显示，总计照旧。
    public func today(at date: Date) -> Int { day == Self.dayKey(for: date) ? today : 0 }

    /// 跨过 UTC+8 零点时清零当日计数；有变化返回 true。
    @discardableResult
    public mutating func rollover(at date: Date) -> Bool {
        let key = Self.dayKey(for: date)
        guard key != day else { return false }
        day = key; today = 0
        return true
    }
    /// Same rule as the relay: never below 0 today, never above the cap; the
    /// total moves by exactly what was applied. Returns the applied change.
    @discardableResult
    public mutating func apply(_ delta: Int, at date: Date) -> Int {
        rollover(at: date)
        let applied = delta > 0 ? min(delta, Self.maxValue-total) : -min(-delta, today)
        today += applied; total += applied
        return applied
    }
    public mutating func increment(at date: Date) { apply(1, at: date) }
    /// 撤销今天的一次计数；今日为 0 时不做任何事。
    public mutating func decrement(at date: Date) { apply(-1, at: date) }
}

/// 某一天（UTC+8）的次数。
public struct DailyCount: Equatable, Identifiable {
    public let day: String
    public let count: Int
    public var id: String { day }
    public init(day: String, count: Int) { self.day = day; self.count = count }
}

/// 每天的次数，按 UTC+8 日期记，只保留最近 `keptDays` 天，用于折线图。
/// 次数为 0 的日子不存。
public struct CounterHistory: Equatable {
    public static let keptDays = 90
    public private(set) var days: [String: Int]

    public init(_ days: [String: Int] = [:]) {
        self.days = days.filter { DailyCounter.validDay($0.key) && (1...DailyCounter.maxValue).contains($0.value) }
    }
    /// 记下这一天到目前为止的次数（覆盖这一天之前记的值）。
    public mutating func record(_ counter: DailyCounter) {
        guard DailyCounter.validDay(counter.day) else { return }
        days[counter.day] = counter.today > 0 ? counter.today : nil
    }
    /// 丢掉 `keptDays` 天之前的记录。
    public mutating func prune(at date: Date) {
        let oldest = DailyCounter.dayKey(daysBefore: Self.keptDays-1, from: date)
        days = days.filter { $0.key >= oldest }
    }
    /// 截至 `date` 的最近 `count` 天（含当天），从早到晚；没记录的日子是 0。
    /// `live` 是正在显示的计数，它那一天以它为准。
    public func series(days count: Int, endingAt date: Date, live: DailyCounter? = nil) -> [DailyCount] {
        var merged = self
        if let live { merged.record(live) }
        return (0..<max(count, 0)).reversed().map { offset in
            let day = DailyCounter.dayKey(daysBefore: offset, from: date)
            return DailyCount(day: day, count: merged.days[day] ?? 0)
        }
    }
    /// 总计里不在按天记录中的次数（早于记录开始，或已超过 `keptDays` 天）。
    public func untracked(total: Int, live: DailyCounter? = nil) -> Int {
        var merged = self
        if let live { merged.record(live) }
        return max(total - merged.days.values.reduce(0, +), 0)
    }
}
