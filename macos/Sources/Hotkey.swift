import AppKit
import Carbon.HIToolbox

/// Watches the dictation key system-wide and turns it into start, stop and cancel, following the
/// chosen mode. A modifier key (Right Command and friends) is read from a listen-only event tap
/// and only counts when pressed on its own: any other key while it is down means it is being
/// used as a modifier, so the dictation is dropped quietly (what was said goes to History only). A recorded shortcut is a Carbon hot
/// key, so the keystroke is consumed instead of also reaching the focused app. The cancel key
/// cancels in every mode.
///
/// In hold mode a modifier trigger has a lock key (Right Option, or Right Command when Right
/// Option is the trigger): pressed while holding, it keeps the dictation listening after the
/// trigger is let go, until the trigger is tapped again. A double-tap of the trigger locks it
/// on straight away.
final class Hotkey {
    struct Config: Equatable {
        var trigger: TriggerKey
        var shortcut: KeyCombo
        var mode: HotkeyMode
        var cancelKey: KeyCombo
        var improveKey: ImproveKey
    }

    var onStart: (() -> Void)?
    /// `held` is true for a press-and-hold that was let go, false for a locked or tap-mode
    /// dictation stopped by a tap.
    var onStop: ((_ held: Bool) -> Void)?
    var onCancel: ((_ deliberate: Bool) -> Void)?
    var onLock: (() -> Void)?
    /// The improve key was tapped on its own. The app decides whether it means anything right now.
    var onImprove: (() -> Void)?
    /// Whether the app is still recording. A tap or hands-free state is dropped once it is not
    /// (Claude never started listening, the session restarted), so the next press starts afresh.
    var isRecording: () -> Bool = { false }

    /// False when another app already owns the recorded shortcut.
    private(set) var shortcutRegistered = true
    var isArmed: Bool { tap != nil }

    private enum Gesture {
        case idle
        /// Pressed from idle; dictation has started.
        case down(since: Date)
        /// Hold mode: a short tap, waiting to see whether a second one follows (double-tap = lock).
        case awaitingSecondTap
        /// The second tap of a double-tap is still down.
        case secondTapDown
        /// Locked, or tap mode: recording until the next tap.
        case handsFree
        /// Pressed while hands-free; a clean release stops, one with other keys in between was
        /// the key used as a modifier.
        case stopDown(interrupted: Bool)
    }

    /// Held at least this long, a press is a hold rather than a tap.
    private static let tapLength: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.35

    private var config: Config?
    private var gesture = Gesture.idle
    private var secondTapTimeout: DispatchWorkItem?
    private var modifierDown = false
    private var partnerDown = false
    private var improveTap = SoloTap()
    /// The lock key tapped again once locked: a second way to the improve key.
    private var lockKeyTap = SoloTap()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// For the log: whether the tap has delivered anything since it was armed.
    fileprivate var sawEvent = false

    /// (Re)arms with `config`, dropping any dictation in progress. Returns false while macOS has
    /// not granted Accessibility yet; a recorded shortcut works without it, the cancel key does not.
    @discardableResult
    func arm(_ config: Config) -> Bool {
        disarm()
        sawEvent = false
        self.config = config
        if config.trigger == .shortcut { registerShortcut(config.shortcut) }
        // An active tap needs Accessibility, which then also lets it see the keys (an app granted
        // Accessibility counts as allowed for Input Monitoring). A listen-only tap needs Input
        // Monitoring itself: the fallback for anyone who granted only that.
        let canListen = CGPreflightListenEventAccess()
        guard canListen || AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let hotkey = Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue()
            if !hotkey.sawEvent {
                hotkey.sawEvent = true
                Log.write("event tap: first key event seen (type \(type.rawValue))")
            }
            let swallow = hotkey.shouldSwallow(type: type, event: event)
            hotkey.handle(type: type, event: event)
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        // An active tap can keep the cancel key from the app in front (needs Accessibility); a
        // listen-only one still works for everything else, so fall back to it.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        var port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: userInfo)
        var kind = "active"
        if port == nil && canListen {
            port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: userInfo)
            kind = "listen-only"
        }
        Log.write("event tap: \(port == nil ? "not created" : kind) (Input Monitoring \(canListen ? "on" : "off"), Accessibility \(AXIsProcessTrusted() ? "on" : "off"))")
        guard let port else { return false }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func disarm() {
        if case .idle = gesture {} else { cancel(deliberate: false) }
        // A key held while disarmed goes up unseen.
        improveTap.reset()
        lockKeyTap.reset()
        swallowedKey = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        shortcutRegistered = true
        modifierDown = false
        partnerDown = false
        config = nil
    }

    // MARK: Key events

    private func registerShortcut(_ combo: KeyCombo) {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { hotkey.triggerDown() } else { hotkey.triggerUp() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, types.count, &types,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x434C_5748), id: 1) // "CLWH"
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        shortcutRegistered = status == noErr
        if !shortcutRegistered { Log.write("could not register shortcut \(combo.display) (\(status))") }
    }

    struct ModifierKey {
        let keyCode: Int64
        let deviceMask: UInt64
        let flag: CGEventFlags
        let name: String
    }

    /// Key codes, and the device-specific bits in CGEventFlags (NX_DEVICE*KEYMASK) that tell the
    /// left key from the right one.
    static func modifierKey(_ trigger: TriggerKey) -> ModifierKey? {
        switch trigger {
        case .rightCommand: return rightCommand
        case .rightOption: return rightOption
        case .leftOption: return ModifierKey(keyCode: 58, deviceMask: 0x20, flag: .maskAlternate, name: "Left Option")
        case .rightControl: return ModifierKey(keyCode: 62, deviceMask: 0x2000, flag: .maskControl, name: "Right Control")
        case .fn: return ModifierKey(keyCode: 63, deviceMask: CGEventFlags.maskSecondaryFn.rawValue, flag: .maskSecondaryFn, name: "Fn")
        case .shortcut: return nil
        }
    }

    /// The lock key; a shortcut has none.
    static func partnerKey(_ trigger: TriggerKey) -> ModifierKey? {
        switch trigger {
        case .shortcut: return nil
        case .rightOption: return rightCommand
        default: return rightOption
        }
    }

    /// The keys the dictation key and its lock key take, and what they do, so the improve key
    /// can't be one of them.
    static func keysInUse(trigger: TriggerKey, mode: HotkeyMode) -> [Int64: String] {
        var keys: [Int64: String] = [:]
        if mode == .hold, let partner = partnerKey(trigger) { keys[partner.keyCode] = "locks dictation" }
        if let key = modifierKey(trigger) { keys[key.keyCode] = "starts dictation" }
        return keys
    }

    private static let rightCommand = ModifierKey(keyCode: 54, deviceMask: 0x10, flag: .maskCommand, name: "Right Command")
    private static let rightOption = ModifierKey(keyCode: 61, deviceMask: 0x40, flag: .maskAlternate, name: "Right Option")

    /// The cancel key while a dictation is going belongs to Claude Whisper alone: it must not also
    /// reach the app in front, where Esc would, say, interrupt Claude Code. Its auto-repeats and
    /// its key-up go with it. Every other key passes through untouched.
    private var swallowedKey: Int64?

    private func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        guard let config, type == .keyDown || type == .keyUp else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if let swallowedKey, code == swallowedKey {
            if type == .keyUp { self.swallowedKey = nil }
            return true
        }
        guard type == .keyDown, code == Int64(config.cancelKey.keyCode), isRecording() else { return false }
        if case .idle = gesture { return false }
        swallowedKey = code
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard let config else { return }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            // The dictation and lock keys win should the improve key be set to one of them.
            if Self.keysInUse(trigger: config.trigger, mode: config.mode)[code] == nil,
               let down = config.improveKey.isDown(keyCode: code, flags: flags.rawValue) {
                if improveTap.key(down: down) { onImprove?() }
                return
            }
            improveTap.otherKey()
            guard let key = Self.modifierKey(config.trigger) else { return }
            let partner = config.mode == .hold ? Self.partnerKey(config.trigger) : nil
            if let partner, code == partner.keyCode {
                let down = flags.rawValue & partner.deviceMask != 0
                if down && !partnerDown {
                    partnerDown = true
                    partnerPressed()
                } else if !down {
                    partnerDown = false
                    if lockKeyTap.key(down: false) { onImprove?() }
                }
                return
            }
            lockKeyTap.otherKey()
            guard code == key.keyCode else { return }
            let down = flags.rawValue & key.deviceMask != 0
            if down && !modifierDown {
                var others = CGEventFlags([.maskCommand, .maskControl, .maskShift, .maskAlternate]).subtracting(key.flag)
                // While locked, a tap stops it even if the lock key is still down.
                if case .handsFree = gesture, let partner { others.remove(partner.flag) }
                guard flags.intersection(others).isEmpty else { return }
                modifierDown = true
                triggerDown()
            } else if !down && modifierDown {
                modifierDown = false
                triggerUp()
            }
        case .keyDown:
            improveTap.otherKey()
            lockKeyTap.otherKey()
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // The shortcut's own key (and its auto-repeat), should the tap get to see it at all.
            if config.trigger == .shortcut && code == Int64(config.shortcut.keyCode) { return }
            otherKey(isCancel: code == Int64(config.cancelKey.keyCode))
        default:
            break
        }
    }

    // MARK: Gestures

    private func triggerDown() {
        dropIfNotRecording()
        switch gesture {
        case .idle:
            onStart?()
            gesture = .down(since: Date())
        case .awaitingSecondTap:
            secondTapTimeout?.cancel()
            gesture = .secondTapDown
            onLock?()
        case .handsFree:
            gesture = .stopDown(interrupted: false)
        default:
            break
        }
    }

    /// The lock key while the trigger is held: keep listening after the trigger is let go.
    /// The lock key: while the trigger is held it locks listening on, so it keeps going after the
    /// trigger is let go. Tapped again once locked (on its own, not as part of a shortcut), it works
    /// like the improve key: a hidden shortcut that keeps the hand where it already is.
    private func partnerPressed() {
        switch gesture {
        case .down:
            gesture = .handsFree
            onLock?()
        case .handsFree, .stopDown:
            _ = lockKeyTap.key(down: true)
        default:
            break
        }
    }

    private func triggerUp() {
        dropIfNotRecording()
        guard let mode = config?.mode else { return }
        switch gesture {
        case .down(let since):
            guard mode == .hold else { gesture = .handsFree; return }
            if Date().timeIntervalSince(since) >= Self.tapLength { return stop(held: true) }
            // Too short to be a hold: the first half of a double-tap, or a stray tap to drop.
            gesture = .awaitingSecondTap
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, case .awaitingSecondTap = self.gesture else { return }
                self.cancel(deliberate: false)
            }
            secondTapTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: timeout)
        case .secondTapDown:
            gesture = .handsFree
        case .stopDown(let interrupted):
            if interrupted { gesture = .handsFree } else { stop(held: false) }
        default:
            break
        }
    }

    private func otherKey(isCancel: Bool) {
        dropIfNotRecording()
        switch gesture {
        case .idle:
            break
        case .handsFree:
            // Locked: only the cancel key or the dictation key ends it; every other key just goes
            // to the app, even with the dictation key still down.
            if isCancel { cancel(deliberate: true) }
        case .stopDown:
            if isCancel { cancel(deliberate: true) } else { gesture = .stopDown(interrupted: true) }
        case .down, .awaitingSecondTap, .secondTapDown:
            cancel(deliberate: isCancel)
        }
    }

    private func dropIfNotRecording() {
        switch gesture {
        case .idle, .down: return
        default: if !isRecording() { reset() }
        }
    }

    private func reset() {
        secondTapTimeout?.cancel()
        secondTapTimeout = nil
        lockKeyTap.reset()
        gesture = .idle
    }

    private func stop(held: Bool) {
        reset()
        onStop?(held)
    }

    private func cancel(deliberate: Bool) {
        reset()
        onCancel?(deliberate)
    }
}
