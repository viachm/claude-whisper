import AppKit
import AVFoundation
import Combine

/// Claude Whisper: hold Right Command (or the key chosen in Settings) anywhere, speak, release, and the
/// text is typed where your cursor is. Transcription is done by Claude Code's own voice mode, in
/// a hidden Claude Code session signed in with your Claude subscription.
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences.shared
    private let history = History()
    private let session = ClaudeSession()
    private lazy var refiner = Refiner(directory: session.workspace)
    private let hotkey = Hotkey()
    private let overlay = Overlay()
    private var statusItem: NSStatusItem!
    private let historyMenu = NSMenu(title: "History")
    private var inputMonitoringTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private lazy var settings = SettingsWindowController(history: history, actions: SettingsActions(
        restartSession: { [weak self] in self?.restartSession() },
        openLog: { [weak self] in self?.openLog() }))
    private var subscriptions = Set<AnyCancellable>()

    private enum Phase { case idle, waitingForMic, listening, transcribing }
    private var phase = Phase.idle
    private var pressID = 0
    /// Locked before Claude was listening: the capsule shows the lock once it is.
    private var locked = false
    /// Whether the dictation being transcribed was held and let go (rather than locked or
    /// tapped), which decides whether it is auto-sent.
    private var held = false
    /// Whether the improve key flipped the cleanup default for the current dictation.
    private var improveToggled = false
    private var improves: Bool { prefs.cleanup.improves(toggled: improveToggled) }
    /// When the key went up, for the timings in the log.
    private var releasedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("Claude Whisper launched")
        setUpMenu()
        requestPermissions()

        hotkey.onStart = { [weak self] in self?.pressed() }
        hotkey.onStop = { [weak self] held in self?.released(held: held) }
        hotkey.onLock = { [weak self] in self?.lockedOn() }
        hotkey.onImprove = { [weak self] in self?.improvePressed() }
        hotkey.onCancel = { [weak self] deliberate in self?.cancelled(deliberate: deliberate) }
        hotkey.isRecording = { [weak self] in self?.phase == .waitingForMic || self?.phase == .listening }
        armHotkey()
        watchPreferences()
        session.onStateChange = { [weak self] state in self?.sessionChanged(state) }
        session.start()
        prepareRefiner()
        // A first start (or one after an update reset the permissions) opens Settings, whose
        // banner leads to what still has to be allowed.
        if Permission.allCases.contains(where: { !$0.isGranted }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.settings.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
        refiner.reset()
        Log.write("Claude Whisper quit")
    }

    // MARK: Menu bar

    private func setUpMenu() {
        // macOS adds new menu bar items to the left of the others. Once, start Claude Whisper at the
        // right end (the stored position is the distance from the right edge); a later
        // Cmd-drag by the user is kept.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "placedAtRightEnd") {
            defaults.set(1, forKey: "NSStatusItem Preferred Position Item-0")
            defaults.set(true, forKey: "placedAtRightEnd")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(active: false)
        let menu = NSMenu()
        historyMenu.delegate = self
        menu.addItem(withTitle: "History", action: nil, keyEquivalent: "").submenu = historyMenu
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Restart Claude Session", action: #selector(restartSession), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        NSApp.mainMenu = mainMenu()
    }

    /// Built each time it opens: the latest dictations, a click copies one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === historyMenu else { return }
        menu.removeAllItems()
        if history.entries.isEmpty {
            menu.addItem(withTitle: "No dictations yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        let time = DateFormatter()
        for entry in history.entries.prefix(10) {
            time.dateFormat = Calendar.current.isDateInToday(entry.date) ? "HH:mm" : "d MMM HH:mm"
            let line = entry.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let snippet = line.count > 60 ? line.prefix(60) + "…" : line
            let item = menu.addItem(withTitle: "\(time.string(from: entry.date))  \(snippet)",
                                    action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            item.toolTip = entry.text
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show All \(history.entries.count)…", action: #selector(showHistory), keyEquivalent: "").target = self
        let clear = menu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !history.entries.isEmpty
    }

    @objc private func copyHistoryEntry(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String else { return }
        copyToClipboard(text)
        show(.message("Copied to clipboard"))
    }

    @objc private func showHistory() { settings.show(tab: .history) }
    @objc private func clearHistory() { history.clear() }

    /// Never shown for a menu bar app, but it is what routes Cmd+C, Cmd+V, Cmd+W and friends to
    /// the Settings window while it is in front.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit Claude Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for submenu in [appMenu, edit, window] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }

    /// A small copy of the app icon: voice bars in a rounded square, outlined while idle and
    /// filled while listening. Drawn as a template so it follows the menu bar's colours.
    private func setIcon(active: Bool) {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { bounds in
            let tile = bounds.insetBy(dx: 1.5, dy: 0.75)
            let shape = NSBezierPath(roundedRect: tile, xRadius: 4.5, yRadius: 4.5)
            NSColor.black.set()
            if active { shape.fill() } else { shape.lineWidth = 1; shape.stroke() }
            let heights: [CGFloat] = [4, 7, 10, 7, 4]
            let barWidth: CGFloat = 1.6, gap: CGFloat = 1.5
            var x = tile.midX - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap) / 2
            // Listening: the bars are cut out of the filled square.
            NSGraphicsContext.current?.compositingOperation = active ? .destinationOut : .sourceOver
            for h in heights {
                NSBezierPath(roundedRect: NSRect(x: x, y: tile.midY - h / 2, width: barWidth, height: h),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude Whisper"
        statusItem.button?.image = image
    }

    private func sessionChanged(_ state: ClaudeSession.State) {
        settings.state.session = state
        refreshHotkeyProblem()
        guard state == .stopped else { return }
        phase = .idle
        setIcon(active: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.session.start() }
    }

    /// Hotkey problems first, since dictation cannot start until they are solved.
    /// Only a shortcut another app owns; missing permissions have their own banner in Settings.
    private func refreshHotkeyProblem() {
        settings.state.hotkeyProblem = prefs.trigger == .shortcut && !hotkey.shortcutRegistered
            ? "\(prefs.shortcut.display) is taken by another app" : nil
    }

    @objc private func openSettings() { settings.show() }

    /// Coalesced, since applying several session settings at once would restart it once each.
    @objc private func restartSession() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.session.restart() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    // MARK: Permissions

    private func requestPermissions() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
            Log.write("waiting for Accessibility permission (needed to paste)")
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.write("microphone access \(granted ? "granted" : "denied")")
        }
    }

    // MARK: Hotkey

    /// Arms the hotkey with the current settings. Without Input Monitoring it checks again every
    /// 2 s, so granting it in System Settings takes effect without a restart.
    private func armHotkey() {
        inputMonitoringTimer?.invalidate()
        inputMonitoringTimer = nil
        defer { refreshHotkeyProblem() }
        // A shortcut field is recording: the old shortcut must not fire meanwhile.
        if prefs.isRecordingShortcut { return hotkey.disarm() }
        let config = Hotkey.Config(trigger: prefs.trigger, shortcut: prefs.shortcut, mode: prefs.mode,
                                   cancelKey: prefs.cancelKey, improveKey: prefs.improveKey)
        if hotkey.arm(config) { return }
        Log.write("waiting for Input Monitoring permission (needed to see the dictation key)")
        CGRequestListenEventAccess()
        inputMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if CGPreflightListenEventAccess() { self?.armHotkey() }
        }
    }

    /// Applies settings as they change: hotkey changes re-arm the event tap right away.
    private func watchPreferences() {
        watch(prefs.$trigger) { [weak self] in self?.armHotkey() }
        watch(prefs.$shortcut) { [weak self] in self?.armHotkey() }
        watch(prefs.$mode) { [weak self] in self?.armHotkey() }
        watch(prefs.$cancelKey) { [weak self] in self?.armHotkey() }
        watch(prefs.$improveKey) { [weak self] in self?.armHotkey() }
        watch(prefs.$isRecordingShortcut) { [weak self] in self?.armHotkey() }
        // Claude reads its arguments and settings only at start.
        watch(prefs.$claudePath) { [weak self] in
            self?.restartSession()
            self?.refiner.reset()
            self?.prepareRefiner()
        }
        watch(prefs.$language) { [weak self] in self?.restartSession() }
        watch(prefs.$cleanup) { [weak self] in self?.prepareRefiner() }
        watch(prefs.$refineModel) { [weak self] in self?.prepareRefiner() }
        watch(prefs.$extraArguments) { [weak self] in self?.restartSession() }
        watch(prefs.$showOverlay) { [weak self] in self?.overlay.hide() }
    }

    /// @Published emits before the property is set, so the action runs on the next main-queue
    /// turn, when reading the preference gives the new value.
    private func watch<T: Equatable>(_ publisher: Published<T>.Publisher, _ action: @escaping () -> Void) {
        publisher.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { _ in action() }.store(in: &subscriptions)
    }

    // MARK: Dictation

    private func pressed() {
        Log.write("dictation key pressed (session \(session.state), phase \(phase))")
        guard phase == .idle else { return }
        guard session.state == .ready else {
            show(.message("Claude is still starting"))
            return
        }
        pressID += 1
        let id = pressID
        phase = .waitingForMic
        locked = false
        improveToggled = false
        overlay.setImprove(prefs.showOverlay && improves)
        show(.waiting)
        session.startRepeats()
        waitForMicrophone(id: id, started: Date())
    }

    /// Claude only opens the microphone once it is really listening; until then, show nothing
    /// that suggests it is.
    private func waitForMicrophone(id: Int, started: Date) {
        guard id == pressID, phase == .waitingForMic else { return }
        if Microphone.isRunning() {
            phase = .listening
            setIcon(active: true)
            show(locked ? .locked : .listening)
            Sound.play("press")
            Log.write("listening after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return
        }
        if Date().timeIntervalSince(started) > 3 {
            Log.write("Claude did not start listening; screen: \(session.tail(300))")
            session.cancel()
            phase = .idle
            show(.message("Claude didn't start listening"))
            Sound.play("Basso")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.waitForMicrophone(id: id, started: started)
        }
    }

    /// The lock key while holding: keeps listening after the key is let go. The capsule shows a
    /// lock and the press cue confirms it (right away, or with the start cue if Claude is not
    /// listening yet).
    private func lockedOn() {
        guard phase == .waitingForMic || phase == .listening else { return }
        Log.write("locked")
        locked = true
        if phase == .listening {
            Sound.play("press")
            show(.locked)
        }
    }

    private func released(held: Bool) {
        switch phase {
        case .waitingForMic:
            // Let go before Claude was listening: nothing to transcribe.
            session.cancel()
            phase = .idle
            overlay.hide()
        case .listening:
            // Only here: a release while an earlier dictation is still being transcribed or cleaned
            // up must not change whether that one gets sent.
            self.held = held
            Sound.play("stop")
            phase = .transcribing
            setIcon(active: false)
            show(.transcribing)
            releasedAt = Date()
            session.finish { [weak self] text in self?.transcribed(text) }
        default:
            break
        }
    }

    private func prepareRefiner() {
        // With cleanup on request, the process starts when the improve key is pressed: the rest of the
        // dictation is enough time for it to get ready, and nothing waits around meanwhile.
        if prefs.cleanup == .always { refiner.prepare(model: prefs.refineModel) } else { refiner.reset() }
    }

    /// The improve key during a dictation switches Claude's cleanup on (or off, when it is always
    /// on) for this dictation; the capsule shows a sparkle while it is on.
    private func improvePressed() {
        guard prefs.cleanup != .off, phase == .waitingForMic || phase == .listening else { return }
        improveToggled.toggle()
        Log.write("cleanup \(improves ? "on" : "off") for this dictation")
        overlay.setImprove(prefs.showOverlay && improves)
        Sound.play("Tink")
        if improves { refiner.prepare(model: prefs.refineModel) }
    }

    private func msSinceRelease() -> Int { Int(Date().timeIntervalSince(releasedAt) * 1000) }

    private func transcribed(_ text: String) {
        Log.write("transcript ready \(msSinceRelease()) ms after release")
        guard !text.isEmpty else {
            phase = .idle
            overlay.hide()
            return
        }
        guard improves else { return deliver(text) }
        // The capsule keeps showing "transcribing" while Claude cleans the text up.
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let id = pressID
        refiner.refine(text, app: app, model: prefs.refineModel, keepWarm: prefs.cleanup == .always) { [weak self] refined in
            guard let self else { return }
            // The session restarted meanwhile and a new dictation began: don't paste into it.
            guard id == self.pressID else {
                self.history.add(refined ?? text)
                return Log.write("cleanup finished after a new dictation started; kept in History only")
            }
            self.deliver(refined ?? text)
            if refined == nil { self.show(.message("Pasted without cleanup")) }
        }
    }

    private func deliver(_ text: String) {
        phase = .idle
        overlay.hide()
        Log.write("\(prefs.output == .copy ? "copying" : "pasting") \(text.count) characters, \(msSinceRelease()) ms after release")
        history.add(text)
        if prefs.output == .copy { show(.message("Copied to clipboard")) }
        let target = NSWorkspace.shared.frontmostApplication
        // A trailing space so the next dictation or typing doesn't run into this one; a message
        // that gets sent is unaffected.
        let pasted = prefs.output == .copy ? text : text + " "
        Paster.deliver(pasted, as: prefs.output, restoreClipboard: prefs.restoreClipboard)
        if prefs.output == .paste && (held || prefs.sendAfterLock) { autoSend(to: target, pastedAt: Date()) }
    }

    /// Return after the paste when the dictation was meant to be sent and went into Claude. A
    /// terminal check can take a moment; Return only goes out if the same app is still in front.
    private func autoSend(to target: NSRunningApplication?, pastedAt: Date) {
        AutoSend.shouldSend(to: target) { send in
            guard send else { return }
            let elapsed = Date().timeIntervalSince(pastedAt)
            guard elapsed < 2, NSWorkspace.shared.frontmostApplication?.processIdentifier == target?.processIdentifier else {
                return Log.write("auto-send: skipped, focus moved")
            }
            Log.write("auto-send: Return in \(target?.bundleIdentifier ?? "?")")
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Paster.returnDelay - elapsed), execute: Paster.pressReturn)
        }
    }

    private func show(_ mode: Overlay.Mode) {
        guard prefs.showOverlay else { return }
        overlay.show(mode)
    }

    private func cancelled(deliberate: Bool) {
        guard phase == .waitingForMic || phase == .listening else { return }
        session.cancel()
        phase = .idle
        setIcon(active: false)
        if deliberate { Sound.play("stop") }
        overlay.hide()
    }
}

// Writing to a claude process that has just exited must fail with EPIPE, not kill the app.
signal(SIGPIPE, SIG_IGN)
Migration.fromShepit()
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
