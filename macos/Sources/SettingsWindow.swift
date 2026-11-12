import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case general, claude, permissions, history, notes, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .claude: return "Claude"
        case .permissions: return "Permissions"
        case .history: return "History"
        case .notes: return "Notes"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .claude: return "terminal"
        case .permissions: return "lock.shield"
        case .history: return "clock.arrow.circlepath"
        case .notes: return "note.text"
        case .about: return "info.circle"
        }
    }

    /// Icon tile colour in the sidebar, like System Settings.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .claude: return .orange
        case .permissions: return .blue
        case .history: return .purple
        case .notes: return .yellow
        case .about: return .teal
        }
    }
}

/// What the Settings window shows but does not own: the session state, why the dictation key
/// cannot work (if it cannot), and which tab to open.
final class SettingsState: ObservableObject {
    @Published var tab = SettingsTab.general
    @Published var session = ClaudeSession.State.stopped
    @Published var hotkeyProblem: String?
    /// Set by "All Notes…" in the menu: Notes scrolls to its history and puts the cursor in search.
    @Published var searchNotes = false
}

struct SettingsActions {
    var openNote: (UUID) -> Void
    var restartSession: () -> Void
    var openLog: () -> Void
    var checkForUpdates: () -> Void
}

/// The one Settings window, a SwiftUI view in a plain NSWindow, created on first use.
final class SettingsWindowController {
    let state = SettingsState()
    private let history: History
    private let notes: NoteStore
    private let actions: SettingsActions
    private var window: NSWindow?

    init(history: History, notes: NoteStore, actions: SettingsActions) {
        self.history = history
        self.notes = notes
        self.actions = actions
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { state.tab = tab }
        if window == nil {
            let view = SettingsView(prefs: .shared, history: history, notes: notes, state: state, actions: actions)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Claude Whisper Settings"
            // A plain title bar: drawing the sidebar under a transparent one left artefacts at the top.
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Opened from another desktop (Space), it comes to the current one instead of staying put.
            window.collectionBehavior = [.moveToActiveSpace]
            HandCursor.install(on: window)
            self.window = window
        }
        // SwiftUI sizes the window lazily; lay it out first so it is centred by its real size.
        window?.layoutIfNeeded()
        centerOnScreen()
        // A menu bar app is not active on its own; without this the window opens behind others.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // macOS may refuse the activation (cooperative activation), leaving the window behind others.
        window?.orderFrontRegardless()
    }

    /// Dead centre of the screen the mouse is on, every time it opens. NSWindow.center() puts
    /// windows in the upper third instead.
    private func centerOnScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        guard let frame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded()))
    }
}

private struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let history: History
    let notes: NoteStore
    @ObservedObject var state: SettingsState
    let actions: SettingsActions
    @State private var missing: [Permission] = []
    @State private var managing = false
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// A sidebar like System Settings: every section is visible and obviously clickable, unlike
    /// the small tab strip it replaces.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(state.tab.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                if !missing.isEmpty { permissionBanner }
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 640)
        .onAppear(perform: refreshPermissions)
        .onReceive(permissionTimer) { _ in refreshPermissions() }
        .sheet(isPresented: $managing) { PermissionsSheet(done: { managing = false }) }
    }

    /// Shown on every page while something is not granted, since dictation cannot work without it.
    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(missing.count == 1
                 ? "\(missing[0].title) is not allowed yet, so dictation can't work."
                 : "\(missing.count) permissions are not allowed yet, so dictation can't work.")
            Spacer()
            Button("Manage…") { managing = true }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func refreshPermissions() {
        let now = Permission.allCases.filter { !$0.isGranted }
        if now != missing { missing = now }
    }

    /// The full-resolution icon from the bundle; NSApp.applicationIconImage can hand back a small
    /// rendition that looks blurry when scaled.
    private static let appIcon: NSImage = Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    // The artwork is full-bleed (macOS rounds it elsewhere), so round it here too.
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Claude Whisper").font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 14)
            ForEach(SettingsTab.allCases) { tab in
                SidebarRow(tab: tab, selected: state.tab == tab) { state.tab = tab }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(width: 190)
        .background(.regularMaterial)
    }

    @ViewBuilder private var pane: some View {
        switch state.tab {
        case .general: GeneralPane(prefs: prefs, state: state)
        case .claude: ClaudePane(prefs: prefs, state: state, actions: actions)
        case .permissions: PermissionsPane()
        case .history: HistoryPane(history: history)
        case .notes: NotesPane(store: notes, state: state, open: actions.openNote)
        case .about: AboutPane(checkForUpdates: actions.checkForUpdates)
        }
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
                Text(tab.title)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor : (hovering ? Color.primary.opacity(0.07) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: General

/// The version, where the project lives, and the unofficial note.
private struct AboutPane: View {
    let checkForUpdates: () -> Void
    private static let site = URL(string: "https://viachm.github.io/claude-whisper/")!
    private static let repo = URL(string: "https://github.com/viachm/claude-whisper")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    HStack {
                        Text(version).textSelection(.enabled)
                        Button("Check for Updates…", action: checkForUpdates)
                    }
                }
            }
            Section {
                LabeledContent("Website") { Link("viachm.github.io/claude-whisper", destination: Self.site) }
                LabeledContent("Source code") { Link("github.com/viachm/claude-whisper", destination: Self.repo) }
                LabeledContent("Report a problem") {
                    Link("GitHub Issues", destination: Self.repo.appendingPathComponent("issues"))
                }
                LabeledContent("License") {
                    Link("MIT", destination: Self.repo.appendingPathComponent("blob/main/LICENSE"))
                }
            } footer: {
                Text("Free and open source. Unofficial: not made by, affiliated with or endorsed by Anthropic.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A Settings section header, in the body text's size and colour so it reads as a heading rather
/// than as one more grey caption.
private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.body.weight(.medium)).foregroundStyle(.primary) }
}

private struct GeneralPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var state: SettingsState
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Key", selection: $prefs.trigger) {
                    ForEach(TriggerKey.allCases) { keyLabel($0).tag($0) }
                }
                if prefs.trigger != .shortcut {
                    KeyboardHint(trigger: prefs.trigger, showLock: prefs.mode == .hold, holdMode: prefs.mode == .hold,
                                 cleanupOn: prefs.cleanup != .off)
                }
                if prefs.trigger == .shortcut {
                    LabeledContent("Shortcut") { KeyField(combo: $prefs.shortcut, prefs: prefs, isShortcut: true) }
                }
                Picker("Mode", selection: $prefs.mode) {
                    ForEach(HotkeyMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Cancel key") { KeyField(combo: $prefs.cancelKey, prefs: prefs, isShortcut: false) }
            } header: {
                SectionTitle("Dictation key")
            } footer: {
                if let problem = state.hotkeyProblem { Text(problem).foregroundStyle(.red) }
            }

            Section {
                Picker("After dictating", selection: $prefs.output) {
                    ForEach(OutputAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Put the previous clipboard back after pasting", isOn: $prefs.restoreClipboard)
                    .disabled(prefs.output == .copy)
            } header: {
                SectionTitle("Pasting")
            } footer: {
                Text("""
                    With Return, a dictation you held the key for is sent straight away, in Claude or any other \
                    app where Return sends; a locked one is only pasted.
                    """)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sounds", isOn: $prefs.playSounds)
                HStack {
                    Picker("Sound", selection: $prefs.soundSet) {
                        ForEach(SoundSet.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: prefs.soundSet) { _, set in Sound.preview(set) }
                    Button {
                        Sound.preview(prefs.soundSet)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Play the start sound")
                }
                .disabled(!prefs.playSounds)
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $prefs.soundVolume, in: 0.02...1) { editing in
                            if !editing { Sound.preview(prefs.soundSet) }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 260)
                }
                .disabled(!prefs.playSounds)
                Toggle("Show the dictation capsule on screen", isOn: $prefs.showOverlay)
                Picker("Capsule position", selection: $prefs.capsulePosition) {
                    ForEach(CapsulePosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.showOverlay)
            } header: {
                SectionTitle("Sound and capsule")
            }

            Section {
                Picker("Improve with Claude", selection: $prefs.cleanup) {
                    ForEach(CleanupMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                ImproveKeyField(prefs: prefs)
                    .disabled(prefs.cleanup == .off)
                Picker("Model", selection: $prefs.refineModel) {
                    ForEach(RefineModel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(prefs.cleanup == .off)
            } header: {
                SectionTitle("Improve")
            } footer: {
                Text("""
                    Claude removes filler words and self-corrections ("option 2, no, option 1" becomes "option 1") and \
                    fixes punctuation, keeping your words and language. Tap the improve key while dictating to switch \
                    it on for that dictation: a sparkle shows on the capsule. It uses your Claude subscription and adds \
                    about a second; if Claude doesn't answer within 10 seconds, the text is pasted as it was transcribed.
                    """)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Claude Whisper at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                                            set: setOpenAtLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Claude Whisper under Login Items to finish.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError { Text(loginError).foregroundStyle(.red) }
            } header: {
                SectionTitle("Startup")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func keyLabel(_ key: TriggerKey) -> Text {
        let symbol = key == .fn ? Text(Image(systemName: "globe")) : Text(key.symbol)
        return symbol + Text("  \(key.title)")
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
            Log.write("open at login: \(error)")
        }
        loginStatus = SMAppService.mainApp.status
    }
}

/// Click, then press the key. A dictation shortcut needs Command, Option or Control (or is an
/// F-key), so it cannot swallow ordinary typing, and Esc gives up recording it. The cancel key is
/// any single key, Esc included. The live hotkey is off while recording.
/// A pointing-hand cursor over the keys that have an explanation. NSCursor push/pop is reset by
/// the hosting view's own cursor handling, so this uses SwiftUI's pointer style (macOS 15+).
private struct PointingHand: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *), active {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}

/// The bottom row of a Mac keyboard with the dictation key, and the lock key while holding, lit
/// up, so it is obvious which physical key is meant.
private struct KeyboardHint: View {
    let trigger: TriggerKey
    let showLock: Bool
    var holdMode = true
    /// Cleanup is available, so the lock key's second tap (it works like the improve key) is worth a mention.
    var cleanupOn = false
    /// The key under the mouse; its explanation appears under the row only while hovering.
    /// Native tooltips (.help) do not appear inside a Form row.
    @State private var hovered: Key?
    @State private var pendingHover: DispatchWorkItem?

    private enum Key: CaseIterable {
        case fn, leftControl, leftOption, leftCommand, space, rightCommand, rightOption, rightControl

        var name: String {
            switch self {
            case .fn: return "Fn (Globe)"
            case .leftControl: return "Left Control"
            case .leftOption: return "Left Option"
            case .leftCommand: return "Left Command"
            case .space: return "Space"
            case .rightCommand: return "Right Command"
            case .rightOption: return "Right Option"
            case .rightControl: return "Right Control"
            }
        }

        var symbol: String {
            switch self {
            case .fn: return ""
            case .leftControl, .rightControl: return "⌃"
            case .leftOption, .rightOption: return "⌥"
            case .leftCommand, .rightCommand: return "⌘"
            case .space: return ""
            }
        }

        static func of(_ trigger: TriggerKey) -> Key? {
            switch trigger {
            case .fn: return .fn
            case .leftOption: return .leftOption
            case .rightCommand: return .rightCommand
            case .rightOption: return .rightOption
            case .rightControl: return .rightControl
            case .shortcut: return nil
            }
        }
    }

    var body: some View {
        let dictate = Key.of(trigger)
        let lock = showLock ? (trigger == .rightOption ? Key.rightCommand : Key.rightOption) : nil
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 5) {
                ForEach(Key.allCases, id: \.self) { key in
                    let role = role(of: key, dictate: dictate, lock: lock)
                    keycap(key, role: role, color: key == dictate ? .accentColor : .orange)
                        .modifier(PointingHand(active: role != nil))
                        .onHover { inside in hover(role != nil && inside ? key : nil) }
                }
            }
            if let hovered {
                tip(for: hovered, role: role(of: hovered, dictate: dictate, lock: lock))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// The explanation follows the mouse after a short pause, so sweeping across the keys does
    /// not make it flicker in and out.
    private func hover(_ key: Key?) {
        pendingHover?.cancel()
        let work = DispatchWorkItem { hovered = key }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (key == nil ? 0.12 : 0.15), execute: work)
    }

    private func role(of key: Key, dictate: Key?, lock: Key?) -> String? {
        key == dictate ? "dictate" : (key == lock ? "lock" : nil)
    }

    /// The explanation for a key; the lock and the sparkle are the same symbols the capsule shows.
    private func tip(for key: Key, role: String?) -> Text {
        switch role {
        case "dictate":
            return Text(holdMode
                ? "\(key.name): hold it while you speak, let go to paste the text. Double-tap it to lock listening on."
                : "\(key.name): tap to start listening, tap again to paste the text.")
        case "lock":
            // 1× locks, 2× (once locked) improves: the same symbols the capsule shows.
            let lock = Text("1× ") + Text(Image(systemName: "lock.fill"))
                + Text("  Lock: press \(key.name) while holding the dictation key, then let go and keep talking; tap the dictation key to stop.")
            guard cleanupOn else { return lock }
            return lock + Text("\n2× ") + Text(Image(systemName: "sparkles"))
                + Text("  Improve: tap \(key.name) again while locked, and Claude improves the text, like the improve key.")
        default:
            return Text(key.name)
        }
    }

    /// Under the lock key: the lock, plus the sparkle when its second tap improves the text, the
    /// same symbols the capsule shows.
    private func caption(_ role: String?, color: Color) -> Text {
        guard role == "lock" else { return Text(role ?? " ").foregroundColor(role == nil ? .clear : color) }
        let icon = Color.secondary
        let lock = Text(Image(systemName: "lock.fill")).foregroundColor(icon)
        guard cleanupOn else { return lock + Text(" lock").foregroundColor(icon) }
        // A dimmer, tighter plus, so the two symbols stand out.
        return lock + Text("\u{2009}+\u{2009}").foregroundColor(icon.opacity(0.5))
            + Text(Image(systemName: "sparkles")).foregroundColor(icon)
    }

    private func keycap(_ key: Key, role: String?, color: Color) -> some View {
        VStack(spacing: 3) {
            Group {
                if key == .fn { Image(systemName: "globe") } else { Text(key.symbol) }
            }
                .font(.system(size: 11, weight: .medium))
                .frame(width: key == .space ? 96 : 27, height: 22)
                .foregroundStyle(role != nil ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(role != nil ? color : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(role != nil ? 0 : 0.12)))
            // With cleanup on, the lock key's later taps switch it, so the caption shows both.
            caption(role, color: color)
                .font(.caption2)
                .fixedSize()
        }
        .contentShape(Rectangle())
    }
}

private struct KeyField: View {
    @Binding var combo: KeyCombo
    let prefs: Preferences
    let isShortcut: Bool
    @State private var monitor: Any?

    var body: some View {
        Button {
            if monitor == nil { start() } else { stop() }
        } label: {
            Text(monitor == nil ? combo.display : "Press a key…").frame(minWidth: 90)
        }
        .onDisappear(perform: stop)
        // Clicking elsewhere or closing the window ends recording, like other shortcut fields.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func start() {
        prefs.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard isShortcut else {
            combo = KeyCombo(event: event, keepModifiers: false)
            return stop()
        }
        let new = KeyCombo(event: event, keepModifiers: true)
        if Int(event.keyCode) == kVK_Escape && new.modifiers == 0 { return stop() }
        guard new.isFunctionKey || !new.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
            return NSSound.beep()
        }
        combo = new
        stop()
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        prefs.isRecordingShortcut = false
    }
}

/// Records the improve key: click, then press the modifier key to use. Keys that can't work are
/// refused with the reason (see `ImproveKey.record`).
private struct ImproveKeyField: View {
    @ObservedObject var prefs: Preferences
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Improve key") {
                HStack {
                    Button {
                        if monitor == nil { start() } else { stop() }
                    } label: {
                        Text(monitor == nil ? prefs.improveKey.display : "Press a modifier key…").frame(width: 170)
                    }
                    // Always there (disabled at the default) so the field doesn't jump when it appears.
                    Button("Reset") {
                        stop()
                        problem = nil
                        prefs.improveKey = .eitherShift
                    }
                    .disabled(prefs.improveKey == .eitherShift && monitor == nil)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let conflict {
                Text(conflict).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    /// A key chosen earlier that the dictation key has taken over since.
    private var conflict: String? {
        let taken = Hotkey.keysInUse(trigger: prefs.trigger, mode: prefs.mode)
        guard prefs.improveKey.keyCodes.allSatisfy({ taken[$0] != nil }) else { return nil }
        return "\(prefs.improveKey.name) also \(taken[prefs.improveKey.keyCodes[0]] ?? "is in use"), so it does nothing here. Choose another key."
    }

    private func start() {
        problem = nil
        // The live hotkey is disarmed meanwhile, so pressing the dictation key here doesn't dictate.
        prefs.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            let result = ImproveKey.record(keyCode: Int64(event.keyCode), flags: flags, isKeyDown: event.type == .keyDown,
                                           taken: Hotkey.keysInUse(trigger: prefs.trigger, mode: prefs.mode))
            switch result {
            case .ignore: break
            case .cancel: stop()
            case .recorded(let key):
                prefs.improveKey = key
                problem = nil
                stop()
            case .rejected(let reason):
                problem = reason.message
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        prefs.isRecordingShortcut = false
    }
}

// MARK: Claude

private struct ClaudePane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var state: SettingsState
    let actions: SettingsActions
    @State private var path = ""
    @State private var arguments = ""
    @State private var fastStart = VoiceKey.isFastStart

    var body: some View {
        Form {
            Section {
                Toggle("Faster start", isOn: $fastStart)
                    .onChange(of: fastStart) { _, on in VoiceKey.setFastStart(on) }
            } footer: {
                Text("Makes Option+K Claude Code's voice key, so listening starts about 0.2 s sooner. Space then no longer starts dictation inside Claude Code itself.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
                HStack {
                    Spacer()
                    Button("Open Log", action: actions.openLog)
                    Button("Restart Session", action: actions.restartSession)
                }
            } header: {
                SectionTitle("Hidden Claude Code session")
            }

            Section {
                Picker("Dictation language", selection: $prefs.language) {
                    Text("Claude Code's own setting").tag("")
                    Divider()
                    ForEach(Preferences.languages, id: \.self) { Text($0.capitalized).tag($0) }
                    if !prefs.language.isEmpty && !Preferences.languages.contains(prefs.language) {
                        Text(prefs.language).tag(prefs.language)
                    }
                }
            } footer: {
                Text("Applies to Claude Whisper's session only; your own Claude Code settings stay as they are. Changing it restarts the session.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("claude binary", text: $path, prompt: Text(Preferences.defaultClaudePath))
                    Button("Choose…", action: choose)
                }
                if !FileManager.default.isExecutableFile(atPath: resolved(path)) {
                    Text("No executable at \(resolved(path)).").foregroundStyle(.red)
                }
                TextField("Extra arguments", text: $arguments, prompt: Text("none"))
                HStack {
                    Spacer()
                    Button("Apply and Restart") {
                        prefs.claudePath = path.trimmingCharacters(in: .whitespaces)
                        prefs.extraArguments = arguments.trimmingCharacters(in: .whitespaces)
                    }
                    .disabled(path == prefs.claudePath && arguments == prefs.extraArguments)
                }
            } header: {
                SectionTitle("Claude Code")
            } footer: {
                Text("Extra arguments go after Claude Whisper's own --settings. Anything that ends the interactive prompt, such as --print, breaks dictation.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            path = prefs.claudePath
            arguments = prefs.extraArguments
            fastStart = VoiceKey.isFastStart
        }
    }

    private var statusText: String {
        switch state.session {
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .stopped: return "Stopped, restarting…"
        }
    }

    private var statusColor: Color {
        switch state.session {
        case .starting: return .orange
        case .ready: return .green
        case .stopped: return .red
        }
    }

    private func resolved(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Preferences.defaultClaudePath : (trimmed as NSString).expandingTildeInPath
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: resolved(path)).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

// MARK: Permissions

/// The permissions still to allow, one row each with a button to the right System Settings pane.
/// Rows tick off live as they are granted; once all are, it offers to relaunch, since a key watcher
/// set up before Accessibility was granted only starts working after a restart.
private struct PermissionsSheet: View {
    let done: () -> Void
    @State private var granted: [Permission: Bool] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Claude Whisper").font(.title2.weight(.semibold))
            Text("""
                Turn Claude Whisper on in each of these System Settings lists. If it isn't in the list, \
                drag it in from the Finder window that opens next to it. If it is on but still not \
                allowed here (an update can do that), remove it with − and drag it in again.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Permission.allCases) { permission in
                let ok = granted[permission] == true
                HStack(spacing: 12) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(ok ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).font(.headline)
                        Text(permission.purpose).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ok {
                        Text("Allowed").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { permission.openSettings() }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                if allGranted { Text("All set.").foregroundStyle(.secondary) }
                Spacer()
                if allGranted {
                    Button("Relaunch Claude Whisper", action: relaunch)
                }
                Button(allGranted ? "Done" : "Later", action: done)
                    .keyboardShortcut(allGranted ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var allGranted: Bool { Permission.allCases.allSatisfy { granted[$0] == true } }

    private func refresh() {
        granted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) })
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

private struct PermissionsPane: View {
    @State private var granted: [Permission: Bool] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: granted[permission] == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(granted[permission] == true ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title)
                            Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(granted[permission] == true ? "Open Settings" : "Grant…") { permission.openSettings() }
                    }
                }
            } footer: {
                Text("macOS ties these to the app's signature, so they survive updates signed with the same certificate. Accessibility takes effect within two seconds of granting it. Input Monitoring isn't needed: Accessibility covers it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        granted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) })
    }
}

// MARK: History

private struct HistoryPane: View {
    @ObservedObject var history: History
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                Spacer()
                Text("Your last \(History.limit) dictations will show up here.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(history.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.date, format: .dateTime.day().month().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.text)
                        }
                        Spacer(minLength: 0)
                        Button("Copy") { copyToClipboard(entry.text) }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text("Kept on this Mac, newest first, up to \(History.limit).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)
        }
        .confirmationDialog("Clear all \(history.entries.count) dictations?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        }
    }
}

// MARK: Notes

private struct NotesPane: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var state: SettingsState
    let open: (UUID) -> Void
    @AppStorage("noteTakerLocale") private var locale = "en-US"
    @AppStorage(NoteModel.key) private var model = NoteModel.sonnet
    @AppStorage("noteTakerKeepAudio") private var keepAudio = true
    @AppStorage("noteTakerImprove") private var improve = true
    @AppStorage(NoteRetention.key) private var retention = NoteRetention.threeMonths
    @AppStorage(NoteContext.textKey) private var context = ""
    @AppStorage(NoteContext.folderKey) private var folder = ""
    @State private var locales: [String] = []
    @State private var search = ""
    @State private var deleting: Note?
    @FocusState private var searchFocused: Bool

    private var supported: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    private var visible: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { note in
            [note.displayTitle ?? "", note.summary ?? "", note.transcript]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if supported {
                    NoteTakerSettings(locale: $locale, model: $model, keepAudio: $keepAudio, improve: $improve,
                                      retention: $retention, context: $context, folder: $folder, locales: locales,
                                      chooseFolder: chooseFolder)
                } else {
                    Section { Text("Note Taker needs macOS 26 or later.").foregroundStyle(.secondary) }
                }
                Section {
                    TextField("Search notes", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .id("history")
                    historyRows
                } header: {
                    historyHeader
                }
            }
            .formStyle(.grouped)
            .onAppear {
                store.reload()
                focusSearchIfAsked(proxy)
            }
            .onChange(of: state.searchNotes) { focusSearchIfAsked(proxy) }
        }
        .onChange(of: retention) { store.prune(retention) }
        .task {
            if #available(macOS 26.0, *) { locales = await SpeechStream.supportedLocales() }
        }
        .confirmationDialog("Delete “\(deleting?.displayTitle ?? "this note")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Note", role: .destructive) {
                if let deleting { store.delete(deleting.id) }
                deleting = nil
            }
        }
    }

    /// "All Notes…" in the menu: jump to the history and put the cursor in search.
    private func focusSearchIfAsked(_ proxy: ScrollViewProxy) {
        guard state.searchNotes else { return }
        state.searchNotes = false
        DispatchQueue.main.async {
            proxy.scrollTo("history", anchor: .top)
            searchFocused = true
        }
    }

    private var historyHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionTitle("Notes History")
            if !store.notes.isEmpty { Text("\(store.notes.count)").foregroundStyle(.secondary) }
            Spacer()
            Button("Open Notes Folder") {
                try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(store.directory)
            }
        }
    }

    @ViewBuilder private var historyRows: some View {
        if store.notes.isEmpty {
            Text("Your notes will show up here.").foregroundStyle(.secondary)
        } else if visible.isEmpty {
            Text("No notes match “\(search)”.").foregroundStyle(.secondary)
        } else {
            ForEach(visible) { note in
                NoteHistoryRow(note: note, subtitle: Self.subtitle(note), canOpen: supported,
                               open: { open(note.id) }, delete: { deleting = note })
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Claude can read files in this folder for background on your calls."
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private static func subtitle(_ note: Note) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(note.started) ? "'Today', HH:mm" : "d MMM yyyy, HH:mm"
        var parts = [f.string(from: note.started)]
        if let duration = note.duration { parts.append("\(max(1, Int(duration / 60))) min") }
        if note.summary != nil { parts.append("summary") }
        return parts.joined(separator: " · ")
    }
}

/// The Note Taker options at the top of Settings › Notes, as grouped sections like the other tabs.
private struct NoteTakerSettings: View {
    @Binding var locale: String
    @Binding var model: NoteModel
    @Binding var keepAudio: Bool
    @Binding var improve: Bool
    @Binding var retention: NoteRetention
    @Binding var context: String
    @Binding var folder: String
    let locales: [String]
    let chooseFolder: () -> Void

    var body: some View {
        Section {
            Picker("Language of calls", selection: $locale) {
                ForEach(locales.isEmpty ? [locale] : locales, id: \.self) { code in
                    Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }
            Toggle("Keep the call audio", isOn: $keepAudio)
            Picker("Delete notes older than", selection: $retention) {
                ForEach(NoteRetention.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            SectionTitle("Recording")
        } footer: {
            Text("""
                Start Note Taker from the menu bar icon. It transcribes on your Mac with Apple's speech recogniser: \
                your microphone as “Me”, the call as “Them”. With the audio kept you can play the call back in the \
                note (about 30 MB an hour).
                """)
            .foregroundStyle(.secondary)
        }

        Section {
            Picker("Model", selection: $model) {
                ForEach(NoteModel.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Clean up the transcript after a call", isOn: $improve)
        } header: {
            SectionTitle("Claude")
        } footer: {
            Text("""
                When you press Stop, Claude titles and summarizes the note. With clean-up on, it first fixes \
                misheard words and names, drops “um”s and splits “Them” into the people who spoke: by name when \
                the call makes it clear, otherwise Speaker 1, Speaker 2. The original stays: ⋯ › Show Original \
                Transcript.
                """)
            .foregroundStyle(.secondary)
        }

        Section {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $context)
                    .font(.body)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                if context.isEmpty {
                    Text("e.g. I'm a developer on project XYZ at Acme. People on my calls: Anna (PM), Oleg (backend).")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            LabeledContent("Folder Claude may read") {
                HStack {
                    Text(folder.isEmpty ? "None" : (folder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !folder.isEmpty { Button("Clear") { folder = "" } }
                    Button("Choose…") { chooseFolder() }
                }
            }
        } header: {
            SectionTitle("Context for Claude")
        } footer: {
            Text("Sent with every summary and question. With a folder, Claude can read files in it (and nothing else) to look up the project, people and terms.")
                .foregroundStyle(.secondary)
        }
    }
}

/// One note in Settings › Notes › history: open it to read, listen or copy.
private struct NoteHistoryRow: View {
    let note: Note
    let subtitle: String
    let canOpen: Bool
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.displayTitle ?? (note.snippet.isEmpty ? "Untitled note" : note.snippet))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if canOpen { Button("Open", action: open) }
            Button(action: delete) { Image(systemName: "trash") }
                .help("Delete this note and its audio")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if canOpen { open() } }
        .contextMenu {
            if canOpen { Button("Open", action: open) }
            Button("Delete…", role: .destructive, action: delete)
        }
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
