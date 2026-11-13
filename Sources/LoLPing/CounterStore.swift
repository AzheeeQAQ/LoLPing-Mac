import AppKit
import PingCore

/// 保存计数，并在 UTC+8 零点自动清零当日计数（应用一直开着也会清零）。
final class CounterStore: ObservableObject {
    @Published private(set) var state: DailyCounter {
        didSet { if state != oldValue { save(); onChange?(state) } }
    }
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

    func increment() { var next = state; next.increment(at: Date()); state = next; scheduleReset() }
    func decrement() { var next = state; next.decrement(at: Date()); state = next; scheduleReset() }

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
    private func save() {
        defaults.set(state.day, forKey: "counterDay")
        defaults.set(state.today, forKey: "counterToday")
        defaults.set(state.total, forKey: "counterTotal")
    }
}
