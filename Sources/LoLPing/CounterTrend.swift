import SwiftUI
import Charts
import PingCore

/// 每日次数折线图：最近 7 / 30 / 90 天，鼠标悬停看某一天。
struct CounterTrendView: View {
    let history: CounterHistory
    /// The counter shown above the chart; it decides today's point.
    let live: DailyCounter
    let shared: Bool
    @Binding var days: Int
    @State private var hovered: Int?

    init(history: CounterHistory, live: DailyCounter, shared: Bool, days: Binding<Int>, hovered: Int? = nil) {
        self.history = history; self.live = live; self.shared = shared
        _days = days; _hovered = State(initialValue: hovered)
    }

    var body: some View {
        let points = history.series(days: days, endingAt: Date(), live: live)
        let untracked = history.untracked(total: live.total, live: live)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(shared ? "房间每日次数" : "每日次数").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("时间范围", selection: $days) {
                    ForEach(AppModel.counterChartRanges, id: \.self) { Text("\($0) 天").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 168)
                .accessibilityLabel("每日次数时间范围")
            }
            readout(points)
            chart(points)
            if untracked > 0 {
                Text("总计里另有 \(untracked) 次没有按天明细（90 天前，或 1.12.0 之前的计数）")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
        }
        .onChange(of: days) { _ in hovered = nil }
    }

    /// One fixed line above the plot: the range summary, or the hovered day.
    private func readout(_ points: [DailyCount]) -> some View {
        let text: String
        if let hovered, points.indices.contains(hovered) {
            let point = points[hovered]
            text = "\(Self.longLabel(point.day))　\(point.count) 次"
        } else {
            let sum = points.reduce(0) { $0 + $1.count }
            if sum == 0 { text = "近 \(days) 天还没有计数" }
            else {
                // Earliest day wins a tie, so the label does not jump as days pass.
                let best = points.enumerated().max { $0.element.count < $1.element.count || ($0.element.count == $1.element.count && $0.offset > $1.offset) }!
                let when = best.offset == points.count-1 ? "今天" : Self.shortLabel(best.element.day)
                text = "近 \(days) 天共 \(sum) 次 · 日均 \(String(format: "%.1f", Double(sum)/Double(days))) · 最多 \(best.element.count) 次（\(when)）"
            }
        }
        return Text(text).font(.system(size: 11)).monospacedDigit().lineLimit(1)
            .foregroundStyle(hovered == nil ? Palette.secondary : Color.primary)
            .accessibilityIdentifier("counterTrendReadout")
    }

    private func chart(_ points: [DailyCount]) -> some View {
        let last = points.count-1
        let scale = Scale(max: points.map(\.count).max() ?? 0)
        // Every day gets a dot at 7 days; at 30 and 90 only today and the hovered day.
        let dots = days <= 7 ? Array(points.indices) : [last]
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                AreaMark(x: .value("日期", index), y: .value("次数", point.count))
                    .foregroundStyle(LinearGradient(colors: [Palette.gold.opacity(0.16), Palette.gold.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("日期", index), y: .value("次数", point.count))
                    .foregroundStyle(Palette.gold)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .accessibilityLabel(Self.longLabel(point.day)).accessibilityValue("\(point.count) 次")
            }
            if let hovered, points.indices.contains(hovered) {
                RuleMark(x: .value("日期", hovered))
                    .foregroundStyle(Palette.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(dots + (hovered.map { points.indices.contains($0) ? [$0] : [] } ?? []), id: \.self) { index in
                PointMark(x: .value("日期", index), y: .value("次数", points[index].count))
                    .symbol { Self.dot(large: index == hovered) }
            }
        }
        // Inset so the edge dots clear the axis labels.
        .chartXScale(domain: 0...max(last, 1), range: .plotDimension(padding: 8))
        .chartYScale(domain: 0...scale.top)
        .chartXAxis {
            AxisMarks(values: Self.labelIndices(points.count)) { value in
                if let index = value.as(Int.self), points.indices.contains(index) {
                    AxisValueLabel(anchor: index == last ? .topTrailing : (index == 0 ? .topLeading : .top)) {
                        Text(index == last ? "今天" : Self.shortLabel(points[index].day))
                            .font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: scale.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.white.opacity(0.07))
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text("\(count)").font(.system(size: 9)).monospacedDigit().foregroundStyle(Palette.secondary) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                            if let value = proxy.value(atX: x, as: Double.self) { hovered = min(max(Int(value.rounded()), 0), last) }
                        case .ended: hovered = nil
                        }
                    }
            }
        }
        .frame(height: 118)
        .padding(.top, 4)
        .accessibilityLabel(shared ? "房间每日次数折线图" : "每日次数折线图")
    }

    /// 8 pt dot with a 2 pt ring of the card colour, so it stays clear of the line.
    private static func dot(large: Bool) -> some View {
        let size: CGFloat = large ? 10 : 8
        return Circle().fill(Palette.card).frame(width: size+4, height: size+4)
            .overlay(Circle().fill(Palette.gold).frame(width: size, height: size))
    }
    /// About six labels whatever the range, always including today at the right.
    static func labelIndices(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let step = count <= 7 ? 1 : (count <= 30 ? 7 : 15)
        return Array(stride(from: count-1, through: 0, by: -step).reversed())
    }
    /// "2026-11-17" → "11/17"
    static func shortLabel(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : day
    }
    /// "2026-11-17" → "11月17日 周二"
    static func longLabel(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = DailyCounter.timeZone
        let weekday = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            .map { ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][calendar.component(.weekday, from: $0)-1] } ?? ""
        return "\(parts[1])月\(parts[2])日 \(weekday)"
    }
    /// Whole-number axis: 0 and up to three clean steps (1, 2, 5 × 10ⁿ) above the busiest day.
    private struct Scale {
        let top: Int, ticks: [Int]
        init(max value: Int) {
            let target = Swift.max(value, 1)
            var step = 1, magnitude = 1
            search: while true {
                for multiple in [1, 2, 5] { step = multiple*magnitude; if step*3 >= target { break search } }
                magnitude *= 10
            }
            top = (target+step-1)/step*step
            ticks = Array(stride(from: 0, through: top, by: step))
        }
    }
}
