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
    public mutating func increment(at date: Date) {
        rollover(at: date)
        guard total < Self.maxValue else { return }
        today += 1; total += 1
    }
    /// 撤销今天的一次计数；今日为 0 时不做任何事。
    public mutating func decrement(at date: Date) {
        rollover(at: date)
        guard today > 0 else { return }
        today -= 1; total -= 1
    }
}
