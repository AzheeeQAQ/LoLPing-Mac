import AppKit
import PingCore

/// 保存计数，并在 UTC+8 零点自动清零当日计数（应用一直开着也会清零）。
final class CounterStore: ObservableObject {
    @Published private(set) var state: DailyCounter {
        didSet { if state != oldValue { recordHistory(); save(); onChange?(state) } }
    }
    /// 每天的次数（最近 90 天），给折线图用。
    @Published private(set) var history: CounterHistory
    /// 每次计数变化（包括零点清零）后调用，用来同步给朋友。
    var onChange: ((DailyCounter) -> Void)?
    private let defaults: UserDefaults
    private var resetTimer: Timer?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        var initial = DailyCounter(day: defaults.string(forKey: "counterDay") ?? "",
                                   today: defaults.integer(forKey: "counterToday"),
                                   total: defaults.integer(forKey: "counterTotal"))
        // The saved day's count goes into the history before it rolls over;
        // this also carries over the count from versions without a history.
        var days = CounterHistory(defaults.dictionary(forKey: "counterHistory") as? [String: Int] ?? [:])
        days.record(initial); days.prune(at: Date())
        history = days
        initial.rollover(at: Date())
        state = initial
        save(); scheduleReset()
        // 睡眠期间计时器会延后，手动改系统时间也不会让它重新对齐，所以这两种情况都重新检查。
        let workspace = NSWorkspace.shared.notificationCenter
        observations.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
        let center = NotificationCenter.default
        observations.append((center, center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
    }
    deinit {
        resetTimer?.invalidate()
        observations.forEach { $0.0.removeObserver($0.1) }
    }

    /// Returns what was actually applied (0 for minus at 0 today).
    @discardableResult func change(_ delta: Int) -> Int {
        var next = state; let applied = next.apply(delta, at: Date()); state = next; scheduleReset()
        return applied
    }
    func increment() { change(1) }
    func decrement() { change(-1) }

    private func refresh() {
        var next = state; next.rollover(at: Date()); state = next
        scheduleReset()
    }
    private func scheduleReset() {
        resetTimer?.invalidate()
        let timer = Timer(fire: DailyCounter.nextReset(after: Date()), interval: 0, repeats: false) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }
    private func recordHistory() {
        var next = history; next.record(state); next.prune(at: Date())
        if next != history { history = next }
    }
    private func save() {
        defaults.set(state.day, forKey: "counterDay")
        defaults.set(state.today, forKey: "counterToday")
        defaults.set(state.total, forKey: "counterTotal")
        defaults.set(history.days, forKey: "counterHistory")
    }
}
