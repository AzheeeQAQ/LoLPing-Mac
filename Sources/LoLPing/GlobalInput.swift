import AppKit
import ApplicationServices
import PingCore

final class GlobalInput {
    enum StartError: LocalizedError {
        case permission, eventTap
        var errorDescription: String? {
            switch self {
            case .permission: return "请先在系统设置中允许 LoLPing 使用辅助功能。"
            case .eventTap: return "无法接收全局按键。请检查辅助功能权限；若系统要求输入监控权限，也请为 LoLPing 开启，然后重试。"
            }
        }
    }
    let machine = GestureMachine()
    var onAction: ((GestureMachine.Action) -> Void)?
    private var pingChord: TriggerChord = .controlOptionCommand
    var onUnavailable: (() -> Void)?
    private let mouseButtonsDown: () -> Bool
    private let specialKeysDown: () -> Modifiers
    init(mouseButtonsDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 }, specialKeysDown: @escaping () -> Modifiers = KeyboardEvent.specialKeysDown) {
        self.mouseButtonsDown = mouseButtonsDown; self.specialKeysDown = specialKeysDown
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var specialTimer: Timer?
    private var keysDown: Set<Int> = []
    private var swallowedKeys: Set<Int> = []
    private var specialKeyEvents: Modifiers = []
    private static let mediaEvent = CGEventType(rawValue: 14)!
    private var swallowedRight = false
    private var recoveryAttempts = 0

    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start(chord: TriggerChord, scale: Double) throws {
        stop()
        guard Self.isTrusted else { throw StartError.permission }
        configure(chord: chord)
        machine.deadZone = WheelGeometry.centerRadius*scale
        machine.reset(blockUntilRelease: !modifiers(CGEventSource.flagsState(.combinedSessionState), for: chord).intersection(chord.modifiers).isEmpty)
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .mouseMoved,
                                   .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel, Self.mediaEvent]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let input = Unmanaged<GlobalInput>.fromOpaque(context).takeUnretainedValue()
            return input.process(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw StartError.eventTap
        }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: newTap, enable: true)
        if !chord.modifiers.intersection(.physicalSpecial).isEmpty {
            let poll = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let self else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                self.selectChord(flags)
                self.routeState(flags, at: NSEvent.mouseLocation)
            }
            specialTimer = poll; RunLoop.main.add(poll, forMode: .common)
        }
    }

    func configure(chord: TriggerChord) {
        pingChord = chord; machine.chord = chord
    }
    func stop() {
        timer?.invalidate(); timer = nil
        specialTimer?.invalidate(); specialTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        keysDown.removeAll(); swallowedKeys.removeAll(); specialKeyEvents = []; swallowedRight = false; recoveryAttempts = 0
        machine.reset()
    }

    func cancelCurrent() {
        timer?.invalidate(); timer = nil
        dispatch(machine.cancel())
    }
    func setWheelCenter(_ center: CGPoint) { dispatch(machine.setWheelCenter(center)) }

    private func modifiers(_ flags: CGEventFlags, for chord: TriggerChord) -> Modifiers {
        KeyboardEvent.standardModifiers(flags).union(specialKeysDown().union(specialKeyEvents).intersection(chord.modifiers))
    }
    private func selectChord(_ flags: CGEventFlags) {
        guard machine.phase == .idle else { return }
        machine.chord = pingChord
    }
    private func routeState(_ flags: CGEventFlags, at point: CGPoint) {
        dispatch(machine.inputChanged(flags: modifiers(flags, for: machine.chord), keys: keysDown, at: point,
                                      otherInputHeld: mouseButtonsDown() || !keysDown.subtracting(machine.chord.keyCodes).isEmpty))
    }
    private func processKey(_ key: Int, isDown: Bool, flags: CGEventFlags, at point: CGPoint) -> Bool {
        if let special = KeyboardEvent.specialModifier(key) {
            if isDown { specialKeyEvents.insert(special) } else { specialKeyEvents.remove(special) }
            selectChord(flags); routeState(flags, at: point)
            return false
        }
        if isDown {
            let repeated = keysDown.contains(key); keysDown.insert(key)
            if swallowedKeys.contains(key) { return true }
            selectChord(flags)
            if machine.chord.keyCodes.contains(key) {
                if !repeated { routeState(flags, at: point) }
                let partial = machine.phase == .idle && modifiers(flags, for: machine.chord) == machine.chord.modifiers &&
                    keysDown.isSubset(of: machine.chord.keyCodes) && !mouseButtonsDown()
                if partial || machine.phase == .arming || machine.phase == .open { swallowedKeys.insert(key); return true }
                return false
            }
            let active = machine.phase == .arming || machine.phase == .open
            cancelCurrent()
            if active && key == 53 { swallowedKeys.insert(key); return true }
        } else {
            keysDown.remove(key)
            routeState(flags, at: point)
            if swallowedKeys.remove(key) != nil { return true }
        }
        return false
    }
    private func point(_ event: CGEvent) -> CGPoint {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: event.location.x, y: mainTop-event.location.y)
    }
    /// Routes an event; diagnostics may pass unposted events without an event tap.
    func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelCurrent()
            recoveryAttempts += 1
            if recoveryAttempts <= 2, Self.isTrusted, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            else { DispatchQueue.main.async { [weak self] in self?.onUnavailable?() } }
            return false
        }
        recoveryAttempts = 0
        switch type {
        case .flagsChanged:
            selectChord(event.flags); routeState(event.flags, at: point(event))
        case .keyDown:
            return processKey(Int(event.getIntegerValueField(.keyboardEventKeycode)), isDown: true, flags: event.flags, at: point(event))
        case .keyUp:
            return processKey(Int(event.getIntegerValueField(.keyboardEventKeycode)), isDown: false, flags: event.flags, at: point(event))
        case Self.mediaEvent:
            if let native = NSEvent(cgEvent: event), let change = KeyboardEvent.keyChange(native) {
                return processKey(change.key, isDown: change.down, flags: event.flags, at: point(event))
            }
        case .mouseMoved:
            dispatch(machine.moved(to: point(event)))
        case .rightMouseDown:
            let active = machine.phase == .arming || machine.phase == .open
            cancelCurrent()
            if active { swallowedRight = true; return true }
        case .rightMouseUp:
            if swallowedRight { swallowedRight = false; return true }
        case .rightMouseDragged:
            if swallowedRight { return true }
        case .leftMouseDown, .otherMouseDown, .leftMouseDragged, .otherMouseDragged, .scrollWheel:
            cancelCurrent()
        default: break
        }
        return false
    }
    private func emit(_ action: GestureMachine.Action) {
        onAction?(action)
    }
    private func dispatch(_ actions: [GestureMachine.Action]) {
        for action in actions {
            switch action {
            case .arm:
                timer?.invalidate()
                let next = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.timer = nil
                    self.dispatch(self.machine.delayElapsed())
                }
                timer = next; RunLoop.main.add(next, forMode: .common)
            case .hide, .dismiss:
                timer?.invalidate(); timer = nil
                emit(action)
            default: emit(action)
            }
        }
    }
}
