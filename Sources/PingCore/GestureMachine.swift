import Foundation
import CoreGraphics

/// Pure state machine. Platform code handles clocks, permissions and rendering.
public final class GestureMachine {
    public enum Phase: Equatable { case idle, arming, open, blocked }
    public enum Action: Equatable {
        case arm(CGPoint), show(CGPoint), hover(PingKind, angle: CGFloat?), hide, dismiss, commit(PingKind, CGPoint)
    }
    public private(set) var phase: Phase = .idle
    public private(set) var selected: PingKind = .generic
    public private(set) var anchor: CGPoint = .zero
    public private(set) var currentModifiers: Modifiers = []
    public private(set) var triggerKeysDown: Set<Int> = []
    public var triggerKeyDown: Bool { !triggerKeysDown.isEmpty }
    public var chord: TriggerChord = .controlOptionCommand
    public var deadZone: CGFloat = WheelGeometry.centerRadius
    private var center: CGPoint = .zero
    private var pointer: CGPoint = .zero
    public init() {}

    public func flagsChanged(_ flags: Modifiers, at point: CGPoint, otherInputHeld: Bool) -> [Action] {
        currentModifiers = flags
        return update(at: point, otherInputHeld: otherInputHeld, allowArm: true)
    }
    public func keyChanged(isDown: Bool, at point: CGPoint, otherInputHeld: Bool) -> [Action] {
        guard chord.keyCode != nil else { return [] }
        triggerKeysDown = isDown ? chord.keyCodes : []
        return update(at: point, otherInputHeld: otherInputHeld, allowArm: isDown)
    }
    public func inputChanged(flags: Modifiers, keys: Set<Int>, at point: CGPoint, otherInputHeld: Bool) -> [Action] {
        currentModifiers = flags; triggerKeysDown = keys.intersection(chord.keyCodes)
        return update(at: point, otherInputHeld: otherInputHeld, allowArm: true)
    }
    private var triggerHeld: Bool { currentModifiers == chord.modifiers && chord.keyCodes.isSubset(of: triggerKeysDown) }
    private var fullyReleased: Bool { currentModifiers.intersection(chord.modifiers).isEmpty && !triggerKeyDown }
    private func update(at point: CGPoint, otherInputHeld: Bool, allowArm: Bool) -> [Action] {
        let flags = currentModifiers
        if phase == .blocked {
            if fullyReleased { phase = .idle }
            return []
        }
        if phase == .idle {
            guard allowArm, triggerHeld else { return [] }
            guard !otherInputHeld else { phase = .blocked; return [] }
            anchor = point; center = point; pointer = point; selected = .generic
            phase = .arming
            return [.arm(point)]
        }
        // Adding an unconfigured modifier cancels instead of committing.
        if otherInputHeld || !flags.subtracting(chord.modifiers).isEmpty { return cancel() }
        if !triggerHeld {
            let wasOpen = phase == .open
            phase = fullyReleased ? .idle : .blocked
            return wasOpen ? [.dismiss, .commit(selected, anchor)] : [.hide]
        }
        return []
    }

    public func delayElapsed() -> [Action] {
        guard phase == .arming, triggerHeld else { return [] }
        phase = .open
        return [.show(anchor)]
    }

    public func setWheelCenter(_ point: CGPoint) -> [Action] {
        center = point
        // At an edge the wheel moves inwards, but the original Ping anchor stays fixed.
        guard hypot(pointer.x - anchor.x, pointer.y - anchor.y) > 4 else { return [] }
        return moved(to: pointer)
    }

    public func moved(to point: CGPoint) -> [Action] {
        pointer = point
        guard phase == .open else { return [] }
        let next = WheelGeometry.selection(at: point, center: center, deadZone: deadZone)
        selected = next
        return [.hover(next, angle: WheelGeometry.direction(at: point, center: center, deadZone: deadZone))]
    }

    public func cancel() -> [Action] {
        let hadGesture = phase == .arming || phase == .open
        phase = fullyReleased ? .idle : .blocked
        selected = .generic
        return hadGesture ? [.hide] : []
    }

    public func reset(blockUntilRelease: Bool = false) {
        phase = blockUntilRelease ? .blocked : .idle
        selected = .generic
        currentModifiers = []
        triggerKeysDown = []
    }
}
