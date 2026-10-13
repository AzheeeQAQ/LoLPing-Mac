import AppKit
import Combine
import PingCore

/// A local monitor only while the shortcut sheet is active. No Accessibility
/// permission, global keyboard monitor, keyboard log, or text input is needed.
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var display = "按下组合键"
    @Published private(set) var message = ""
    private let capture = ShortcutCapture()
    private var monitor: Any?
    private var poll: Timer?
    private var deactivateObserver: NSObjectProtocol?
    private var accept: ((TriggerChord) -> Bool)?
    private var waitingForRelease = false
    private var specialKeyEvents: Modifiers = []

    func start(accept: @escaping (TriggerChord) -> Bool) {
        stop(); self.accept = accept; capture.reset()
        isRecording = true; message = "按下组合键，全部松开后自动保存。"
        display = "正在录入…"
        waitingForRelease = !currentModifiers().isEmpty
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .systemDefined, KeyboardEvent.keyChange(event) == nil { return event }
            self.record(event)
            return nil
        }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.flagsChanged(self.capture.modifiers.intersection(.standard).union(KeyboardEvent.specialKeysDown()).union(self.specialKeyEvents))
        }
        poll = timer; RunLoop.main.add(timer, forMode: .common)
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(); self?.message = "窗口已失去焦点，点击重新录入继续。"
        }
    }
    private func currentModifiers() -> Modifiers {
        KeyboardEvent.standardModifiers(CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.rawValue)))
            .union(KeyboardEvent.specialKeysDown())
    }
    private func record(_ event: NSEvent) {
        var edge: Modifiers = []
        if event.type != .systemDefined, let special = KeyboardEvent.specialModifier(Int(event.keyCode)) {
            if event.type == .keyDown { specialKeyEvents.insert(special) }
            if event.type == .keyUp { specialKeyEvents.remove(special) }
            if event.type == .flagsChanged,
               special == .capsLock || event.modifierFlags.contains(.function) { edge.insert(special) }
        }
        flagsChanged(KeyboardEvent.standardModifiers(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            .union(KeyboardEvent.specialKeysDown()).union(specialKeyEvents).union(edge))
        guard isRecording, !waitingForRelease else { return }
        if let key = KeyboardEvent.keyChange(event) { complete(capture.keyChanged(key.key, isDown: key.down)) }
        if isRecording, let candidate = capture.candidate { display = candidate.symbols }
    }
    private func flagsChanged(_ modifiers: Modifiers) {
        if waitingForRelease {
            if modifiers.isEmpty { waitingForRelease = false }
            return
        }
        complete(capture.flagsChanged(modifiers))
        if isRecording, let candidate = capture.candidate { display = candidate.symbols }
    }
    private func complete(_ chord: TriggerChord?) {
        guard let chord else { return }
        if accept?(chord) == true {
            display = chord.symbols; stop(); message = "已自动保存，下次打开仍会记住。"
        } else {
            capture.reset(); display = "请换一组按键"
            message = "和另一套快捷键重叠，请直接输入另一组。"
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        poll?.invalidate(); poll = nil
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }; deactivateObserver = nil
        isRecording = false; capture.reset(); accept = nil; specialKeyEvents = []
    }
}
