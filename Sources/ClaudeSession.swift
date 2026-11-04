import Foundation

/// A hidden Claude Code session running in its own pseudo-terminal. Claude Whisper drives its voice
/// mode: holding is simulated by writing Claude's voice key (see `VoiceKey`) into the terminal
/// every 50 ms, the transcript lands in Claude's prompt, and Ctrl+G (external editor) hands the prompt text
/// to `claude-whisper-capture`, which writes it to the outbox file and empties the prompt.
final class ClaudeSession {
    enum State { case stopped, starting, ready }

    private(set) var state: State = .stopped { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?

    private var masterFD: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var repeatTimer: DispatchSourceTimer?
    private let ioQueue = DispatchQueue(label: "claudewhisper.pty", qos: .userInteractive)

    /// Plain text (escape sequences stripped) of recent terminal output, and when it last changed.
    private var screen = ""
    private var lastOutput = Date.distantPast
    private var lastChunk = ""

    let workspace: URL
    let outbox: URL

    init() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude Whisper")
        workspace = support.appendingPathComponent("workspace")
        outbox = support.appendingPathComponent("outbox.txt")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    // MARK: Lifecycle

    func start() {
        guard state == .stopped else { return }
        state = .starting
        screen = ""

        var master: Int32 = 0, slave: Int32 = 0
        var size = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            Log.write("openpty failed: \(errno)")
            state = .stopped
            return
        }

        let prefs = Preferences.shared
        let claude = prefs.resolvedClaudePath
        let args = [claude, "--settings", Self.settingsJSON(language: prefs.language)] + prefs.extraArgumentList
        let capture = Self.editorScript()
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        env["TERM"] = "xterm-256color"
        env["EDITOR"] = capture
        env["VISUAL"] = capture
        env["CLAUDE_WHISPER_OUTBOX"] = outbox.path
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, workspace.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        let rc = posix_spawn(&pid, claude, &actions, &attr, cArgs, cEnv)
        close(slave)
        guard rc == 0 else {
            Log.write("could not start \(claude): \(String(cString: strerror(rc)))")
            close(master)
            state = .stopped
            return
        }
        masterFD = master
        Log.write("started Claude Code (pid \(pid)) in \(workspace.path): \(args.dropFirst().joined(separator: " "))")

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(master) }
        readSource = source
        source.resume()

        let child = pid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            DispatchQueue.main.async { self?.childExited(child, status: status) }
        }
    }

    /// Settings layered over the user's own for this session only: voice on, held key, never
    /// submit, and the dictation language when one is chosen in Claude Whisper.
    private static func settingsJSON(language: String) -> String {
        var settings: [String: Any] = ["voice": ["enabled": true, "mode": "hold", "autoSubmit": false]]
        if !language.isEmpty { settings["language"] = language }
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Claude Code splits $EDITOR on spaces, and the app's own path has one ("Claude Whisper.app"),
    /// so the capture script is copied to a path without spaces and run from there.
    private static func editorScript() -> String {
        let bundled = Bundle.main.url(forResource: "claude-whisper-capture", withExtension: nil)!
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/io.github.viachm.ClaudeWhisper")
        let copy = dir.appendingPathComponent("claude-whisper-capture")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: bundled, to: copy)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            return copy.path
        } catch {
            Log.write("could not copy the capture script: \(error)")
            return bundled.path
        }
    }

    func stop() {
        stopRepeats()
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        let child = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { kill(child, SIGKILL) }
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.start() }
    }

    private func childExited(_ child: pid_t, status: Int32) {
        guard child == pid else { return }
        Log.write("Claude Code exited (status \(status)); last screen: \(tail(400))")
        readSource?.cancel()
        readSource = nil
        masterFD = -1
        pid = 0
        state = .stopped
    }

    // MARK: Terminal output

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(masterFD, &buffer, buffer.count)
        guard n > 0 else { return }
        let data = Data(buffer[0..<n])
        answerQueries(data)
        let text = Self.strip(String(decoding: data, as: UTF8.self))
        DispatchQueue.main.async { [weak self] in self?.received(text) }
    }

    /// Claude asks the terminal where the cursor is and what it is; answer like a basic terminal.
    private func answerQueries(_ data: Data) {
        if data.range(of: Data("\u{1b}[6n".utf8)) != nil { write("\u{1b}[1;1R") }
        if data.range(of: Data("\u{1b}[c".utf8)) != nil || data.range(of: Data("\u{1b}[0c".utf8)) != nil {
            write("\u{1b}[?62;22c")
        }
    }

    private func received(_ text: String) {
        lastOutput = Date()
        lastChunk = text
        screen += text
        if screen.count > 20000 { screen = String(screen.suffix(10000)) }
        if state == .starting {
            if screen.contains("trust this folder") {
                // First run in the workspace: pick "Yes, I trust this folder".
                screen = ""
                write("\u{1b}[B")
                ioQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.write("\r") }
            } else if screen.contains("shift+tab to cycle") || screen.contains("? for shortcuts") || screen.contains("Try \"") {
                state = .ready
                Log.write("Claude Code is ready")
            }
        }
    }

    private static let escapes = try! NSRegularExpression(
        pattern: "\u{1b}\\[[0-9;?<>=]*[ -/]*[@-~]|\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)|\u{1b}.")

    private static func strip(_ s: String) -> String {
        escapes.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    func tail(_ n: Int) -> String {
        String(screen.suffix(n)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // MARK: Dictation

    private func write(_ s: String) {
        guard masterFD >= 0 else { return }
        _ = s.withCString { Darwin.write(masterFD, $0, strlen($0)) }
    }

    /// Starts holding the voice key: it is sent every 50 ms, like a physically held key.
    func startRepeats() {
        stopRepeats()
        let key = VoiceKey.bytes()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.write(key) }
        repeatTimer = timer
        timer.resume()
    }

    func stopRepeats() {
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    /// Releases the voice key and waits for Claude to finish transcribing, then takes the
    /// prompt text out of Claude. Calls back on the main queue with the text ("" if none).
    func finish(completion: @escaping (String) -> Void) {
        stopRepeats()
        let mark = screen.count
        let started = Date()
        var sawProcessing = false

        func poll() {
            let since = String(screen.suffix(max(0, screen.count - mark)))
            let quiet = Date().timeIntervalSince(lastOutput)
            let elapsed = Date().timeIntervalSince(started)
            if since.contains("No speech detected") {
                Log.write("no speech detected")
                return completion("")
            }
            if since.contains("processing") { sawProcessing = true }
            let stillProcessing = lastChunk.contains("processing")
            let done = (sawProcessing && !stillProcessing && quiet > 0.4)
                || (!sawProcessing && elapsed > 2.5 && quiet > 0.6)
                || elapsed > 20
            if done { return capture(completion: completion) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
    }

    /// Drops whatever is being recorded: releases the key and cancels with Esc, then clears
    /// anything that still lands in the prompt.
    func cancel() {
        stopRepeats()
        ioQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.write("\u{1b}") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.capture { text in if !text.isEmpty { Log.write("discarded: \(text)") } }
        }
    }

    /// Ctrl+G: Claude opens the prompt in $EDITOR (claude-whisper-capture), which writes the text to
    /// the outbox and empties the prompt.
    private func capture(completion: @escaping (String) -> Void) {
        try? FileManager.default.removeItem(at: outbox)
        write("\u{07}")
        let started = Date()
        func poll() {
            if let text = try? String(contentsOf: outbox, encoding: .utf8) {
                return completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if Date().timeIntervalSince(started) > 4 {
                Log.write("capture timed out; screen: \(tail(300))")
                return completion("")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }
}
