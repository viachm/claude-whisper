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
    private let updater = Updater()
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private var statusItem: NSStatusItem!
    private let historyMenu = NSMenu(title: "History")
    private let notesMenu = NSMenu(title: "Notes")
    private let noteTakerItem = NSMenuItem(title: "Start Note Taker", action: #selector(noteTakerClicked), keyEquivalent: "")
    private let noteStore = NoteStore()
    /// The NoteTakerWindow, which needs macOS 26 (typed loosely so the app still runs on 14).
    private var noteWindowBox: AnyObject?
    /// The red dot on the menu bar icon while Note Taker records.
    private var recordingDot: NSView?
    private var iconActive = false
    private var accessibilityTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private lazy var settings = SettingsWindowController(history: history, notes: noteStore, actions: SettingsActions(
        openNote: { [weak self] id in MainActor.assumeIsolated { self?.openNote(id: id) } },
        restartSession: { [weak self] in self?.restartSession() },
        openLog: { [weak self] in self?.openLog() },
        checkForUpdates: { [weak self] in self?.checkForUpdates() }))
    private var subscriptions = Set<AnyCancellable>()

    private enum Phase { case idle, waitingForMic, listening, transcribing }
    private var phase = Phase.idle
    private var pressID = 0
    /// Locked before Claude was listening: the capsule shows the lock once it is.
    private var locked = false
    /// Whether the dictation being transcribed was held and let go (rather than locked or
    /// tapped), which decides whether "Paste and press Return" presses Return.
    private var held = false
    /// Whether the improve key flipped the cleanup default for the current dictation.
    private var improveToggled = false
    private var improves: Bool { prefs.cleanup.improves(toggled: improveToggled) }
    /// When the key went up, for the timings in the log.
    private var releasedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("Claude Whisper launched")
        // Read before setUpMenu stores its first key: someone updating from a version without
        // "launchedBefore" has started the app before.
        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
            && UserDefaults.standard.object(forKey: "placedAtRightEnd") == nil
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        // Faster start is on for a new user: listening starts about 0.3 s sooner. It edits their
        // ~/.claude/keybindings.json, so someone updating keeps whatever they chose.
        if firstLaunch && !VoiceKey.isFastStart { VoiceKey.setFastStart(true) }
        setUpMenu()
        requestPermissions()
        MainActor.assumeIsolated { pruneNotes() }
        // Once a day for a Mac that stays up for weeks.
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneNotes() }
        }

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
        updater.onChange = { [weak self] in self?.refreshUpdateItem() }
        // The very first start opens Settings, so a menu bar app with no window doesn't look like it
        // did nothing; so does any start while a permission is missing, whose banner leads to it.
        if firstLaunch || Permission.allCases.contains(where: { !$0.isGranted }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.settings.show() }
        }
    }

    /// Quitting (the menu, logging out, an update, or a plain `kill`) while a note records: the
    /// note is finished and saved first, for up to 5 seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard #available(macOS 26.0, *) else { return .terminateNow }
        return MainActor.assumeIsolated {
            guard let taker = (noteWindowBox as? NoteTakerWindow)?.taker, taker.isRecording else { return .terminateNow }
            var replied = false
            let reply = {
                guard !replied else { return }
                replied = true
                sender.reply(toApplicationShouldTerminate: true)
            }
            taker.stopForQuit(reply)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: reply)
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if #available(macOS 26.0, *) { MainActor.assumeIsolated { (noteWindowBox as? NoteTakerWindow)?.taker.stop() } }
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
        menu.delegate = self
        noteTakerItem.target = self
        menu.addItem(noteTakerItem)
        notesMenu.delegate = self
        menu.addItem(withTitle: "Notes", action: nil, keyEquivalent: "").submenu = notesMenu
        menu.addItem(.separator())
        historyMenu.delegate = self
        menu.addItem(withTitle: "History", action: nil, keyEquivalent: "").submenu = historyMenu
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // macOS 26 menus show a symbol next to most items (it adds one to Settings by itself);
        // older ones have none, so neither do these there.
        if #available(macOS 26.0, *) {
            let symbols = ["Start Note Taker": "record.circle", "Notes": "note.text", "History": "clock.arrow.circlepath",
                           "Check for Updates…": "arrow.down.circle", "Quit Claude Whisper": "power"]
            for item in menu.items {
                if let name = symbols[item.title] { item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil) }
            }
        }
        statusItem.menu = menu
        NSApp.mainMenu = mainMenu()
    }

    /// Built each time it opens: the latest dictations, a click copies one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu { return MainActor.assumeIsolated { refreshNoteTakerItem() } }
        if menu === notesMenu { return buildNotesMenu() }
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

    // MARK: Note Taker

    @available(macOS 26.0, *)
    @MainActor private var noteWindow: NoteTakerWindow {
        if let window = noteWindowBox as? NoteTakerWindow { return window }
        let window = NoteTakerWindow(taker: NoteTaker(store: noteStore, workspace: session.workspace))
        noteWindowBox = window
        let taker = window.taker
        watch(taker.$isRecording) { [weak self] in self?.showRecordingDot(taker.isRecording, paused: taker.isPaused) }
        watch(taker.$isPaused) { [weak self] in self?.showRecordingDot(taker.isRecording, paused: taker.isPaused) }
        return window
    }

    /// Deletes notes older than Settings › Notes › "Delete notes older than" (3 months by default).
    @MainActor private func pruneNotes() {
        var recording: UUID?
        if #available(macOS 26.0, *), let taker = (noteWindowBox as? NoteTakerWindow)?.taker, taker.isRecording {
            recording = taker.note?.id
        }
        let count = noteStore.prune(keeping: recording)
        if count > 0 { Log.write("deleted \(count) note(s) older than \(NoteRetention.current.title)") }
    }

    @MainActor private func refreshNoteTakerItem() {
        guard #available(macOS 26.0, *) else {
            noteTakerItem.title = "Note Taker (needs macOS 26)"
            noteTakerItem.isEnabled = false
            return
        }
        let window = noteWindowBox as? NoteTakerWindow
        noteTakerItem.title = window?.taker.isRecording == true ? "Show Note Taker" : "Start Note Taker"
    }

    /// Starts a new note, or brings the window back while one is recording.
    @MainActor @objc private func noteTakerClicked() {
        guard #available(macOS 26.0, *) else { return }
        if !noteWindow.taker.isRecording { noteWindow.taker.start() }
        noteWindow.show()
    }

    /// The latest notes; a click opens one in the Note Taker window.
    private func buildNotesMenu() {
        notesMenu.removeAllItems()
        noteStore.reload()
        if noteStore.notes.isEmpty {
            notesMenu.addItem(withTitle: "No notes yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        let time = DateFormatter()
        for note in noteStore.notes.prefix(15) {
            time.dateFormat = Calendar.current.isDateInToday(note.started) ? "HH:mm" : "d MMM HH:mm"
            var title = time.string(from: note.started)
            if let duration = note.duration { title += " · \(max(1, Int(duration / 60))) min" }
            if let name = note.displayTitle ?? (note.snippet.isEmpty ? nil : note.snippet) { title += "  \(name)" }
            let item = notesMenu.addItem(withTitle: title, action: #selector(openNote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = note.id
        }
        notesMenu.addItem(.separator())
        notesMenu.addItem(withTitle: "All Notes…", action: #selector(showAllNotes), keyEquivalent: "").target = self
    }

    @MainActor @objc private func openNote(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        openNote(id: id)
    }

    @MainActor private func openNote(id: UUID) {
        guard #available(macOS 26.0, *), let note = noteStore.notes.first(where: { $0.id == id }) else { return }
        noteWindow.taker.open(note)
        noteWindow.show()
    }

    /// Settings › Notes, scrolled to the history with the cursor in its search field.
    @objc private func showAllNotes() {
        settings.state.searchNotes = true
        settings.show(tab: .notes)
    }
    @objc private func clearHistory() { history.clear() }

    /// Never shown for a menu bar app, but it is what routes Cmd+C, Cmd+V, Cmd+W, Cmd+M and friends
    /// to the Settings and Note Taker windows while they are in front.
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
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for submenu in [appMenu, edit, window] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }

    /// A small copy of the app icon: voice bars in a rounded square, outlined while idle and
    /// filled while listening. Drawn as a template so it follows the menu bar's colours.
    private func setIcon(active: Bool) {
        iconActive = active
        // While a note records and nothing is dictated, the bars give way to the red dot.
        let bars = active || recordingDot == nil
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
            for h in heights where bars {
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

    /// A dot in the middle of the icon while a note records, like a record button: red, or grey
    /// while paused. The icon is a template image (one colour), so the dot is its own view on top.
    private func showRecordingDot(_ recording: Bool, paused: Bool) {
        guard let button = statusItem.button else { return }
        guard recording else {
            recordingDot?.removeFromSuperview()
            recordingDot = nil
            setIcon(active: iconActive)
            button.setAccessibilityLabel(nil)
            return
        }
        let dot = recordingDot ?? {
            let size: CGFloat = 9
            let view = NSView(frame: NSRect(x: (button.bounds.midX - size / 2).rounded(),
                                            y: (button.bounds.midY - size / 2).rounded(), width: size, height: size))
            view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            view.wantsLayer = true
            view.layer?.cornerRadius = size / 2
            button.addSubview(view)
            recordingDot = view
            setIcon(active: iconActive)
            return view
        }()
        dot.layer?.backgroundColor = (paused ? NSColor.systemGray : NSColor.systemRed).cgColor
        button.setAccessibilityLabel(paused ? "Claude Whisper, note paused" : "Claude Whisper, recording a note")
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

    /// Once a check found a newer release, the item offers it straight away.
    @objc private func checkForUpdates() {
        if updater.available != nil { updater.offer() } else { updater.check() }
    }

    private func refreshUpdateItem() {
        updateItem.title = updater.available?.version.map { "Update to \($0)…" } ?? "Check for Updates…"
    }

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

    /// Arms the hotkey with the current settings. Without Accessibility it checks again every 2 s, so
    /// granting it in System Settings takes effect without a restart.
    private func armHotkey() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        defer { refreshHotkeyProblem() }
        // A shortcut field is recording: the old shortcut must not fire meanwhile.
        if prefs.isRecordingShortcut { return hotkey.disarm() }
        let config = Hotkey.Config(trigger: prefs.trigger, shortcut: prefs.shortcut, mode: prefs.mode,
                                   cancelKey: prefs.cancelKey, improveKey: prefs.improveKey)
        if hotkey.arm(config) { return }
        Log.write("waiting for Accessibility permission (needed to see the dictation key)")
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() || CGPreflightListenEventAccess() { self?.armHotkey() }
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
        watch(prefs.$language) { [weak self] in
            self?.restartSession()
            self?.prepareRefiner()
        }
        watch(prefs.$cleanup) { [weak self] in self?.prepareRefiner() }
        watch(prefs.$refineModel) { [weak self] in self?.prepareRefiner() }
        watch(prefs.$extraArguments) { [weak self] in self?.restartSession() }
        watch(prefs.$showOverlay) { [weak self] in self?.overlay.hide() }
        // Show where the capsule will be from now on.
        watch(prefs.$capsulePosition) { [weak self] in self?.show(.message("Dictation shows here")) }
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
            // A stuck session rarely recovers by itself; a fresh one is ready in about a second.
            restartSession()
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
        Sound.play("improve")
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
            if refined == nil { self.show(.message("Pasted without improving")) }
        }
    }

    private func deliver(_ text: String) {
        phase = .idle
        overlay.hide()
        Log.write("\(prefs.output == .copy ? "copying" : "pasting") \(text.count) characters, \(msSinceRelease()) ms after release")
        history.add(text)
        if prefs.output == .copy { show(.message("Copied to clipboard")) }
        // A trailing space so the next dictation or typing doesn't run into this one; a message
        // that gets sent is unaffected.
        let pasted = prefs.output == .copy ? text : text + " "
        // Return only after a hold: a locked dictation is inserted unsent.
        let action: OutputAction = prefs.output == .pasteAndReturn && !held ? .paste : prefs.output
        Paster.deliver(pasted, as: action, restoreClipboard: prefs.restoreClipboard)
    }

    private func show(_ mode: Overlay.Mode) {
        guard prefs.showOverlay else { return }
        overlay.show(mode)
    }

    private func cancelled(deliberate: Bool) {
        guard phase == .waitingForMic || phase == .listening else { return }
        setIcon(active: false)
        overlay.hide()
        // The dictation key used in a shortcut: nothing is pasted, but what was said so far is kept
        // in History rather than lost.
        if !deliberate && phase == .listening {
            phase = .transcribing
            session.finish { [weak self] text in
                guard let self else { return }
                self.phase = .idle
                guard !text.isEmpty else { return }
                self.history.add(text)
                Log.write("dictation dropped; kept \(text.count) characters in History")
            }
            return
        }
        session.cancel()
        phase = .idle
        if deliberate { Sound.play("stop") }
    }
}

// Writing to a claude process that has just exited must fail with EPIPE, not kill the app.
signal(SIGPIPE, SIG_IGN)
// A plain `kill` (SIGTERM) quits through NSApp.terminate, so a note being recorded is saved first.
signal(SIGTERM, SIG_IGN)
let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSignal.setEventHandler {
    Log.write("asked to quit (SIGTERM)")
    NSApp.terminate(nil)
}
terminationSignal.resume()
Migration.fromShepit()
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
