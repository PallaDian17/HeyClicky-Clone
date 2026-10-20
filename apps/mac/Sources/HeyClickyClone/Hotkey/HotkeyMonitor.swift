import AppKit
import CoreGraphics

/// Global modifier-key gestures via a listen-only CGEvent tap.
///
/// Gestures on the configured modifier (Control by default):
/// - double-tap            -> `.doubleTap`
/// - double-tap, then hold -> `.holdBegan` … `.holdEnded`
/// - Escape key            -> `.escape`
///
/// Requires Accessibility (or Input Monitoring) permission; `start()` throws
/// until it is granted. Callbacks arrive on the main thread.
final class HotkeyMonitor {
    enum Event { case doubleTap, holdBegan, holdEnded, escape }
    enum Failure: Error { case tapUnavailable }

    var onEvent: ((Event) -> Void)?
    var modifier: CGEventFlags = .maskControl
    var doubleTapWindow: TimeInterval = 0.35
    var holdThreshold: TimeInterval = 0.28

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var modifierDown = false
    private var lastPress: TimeInterval = 0
    private var pressCount = 0
    private var holding = false
    private var holdTimer: DispatchWorkItem?

    func start() throws {
        guard !isRunning else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            throw Failure.tapUnavailable
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { // Escape
                emit(.escape)
            } else {
                // Any other key while the modifier is down means it's a shortcut, not a gesture.
                pressCount = 0
            }
        case .flagsChanged:
            let down = event.flags.contains(modifier)
            let allModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
            let otherModifiers = allModifiers.subtracting(modifier)
            let others = !event.flags.intersection(otherModifiers).isEmpty
            guard down != modifierDown else { return }
            modifierDown = down
            if others { pressCount = 0; return }
            down ? pressed() : released()
        default:
            break
        }
    }

    private func pressed() {
        let now = Date().timeIntervalSinceReferenceDate
        pressCount = (now - lastPress) < doubleTapWindow ? pressCount + 1 : 1
        lastPress = now
        guard pressCount == 2 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.modifierDown, self.pressCount == 2 else { return }
            self.holding = true
            self.emit(.holdBegan)
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private func released() {
        holdTimer?.cancel()
        holdTimer = nil
        if holding {
            holding = false
            pressCount = 0
            emit(.holdEnded)
        } else if pressCount == 2 {
            pressCount = 0
            emit(.doubleTap)
        }
    }

    private func emit(_ event: Event) {
        Log.hotkey.debug("\(String(describing: event), privacy: .public)")
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [onEvent] in onEvent?(event) }
        }
    }
}
