import AppKit

/// Decides whether a dictation meant to be sent (a hold, or the chord) gets Return after it is
/// pasted: in the Claude desktop app, in a terminal whose focused tab is running Claude Code, and
/// in apps the user added. Hands-free dictations never ask, so they are only inserted.
enum AutoSend {
    static let claudeApp = "com.anthropic.claudefordesktop"
    static let terminalNames = "Ghostty, Terminal or iTerm2"

    /// AppleScript returning the focused tab's tty, per terminal.
    private static let ttyScripts = [
        "com.mitchellh.ghostty":
            #"tell application id "com.mitchellh.ghostty" to get tty of focused terminal of selected tab of front window"#,
        "com.apple.Terminal": #"tell application id "com.apple.Terminal" to get tty of selected tab of front window"#,
        "com.googlecode.iterm2": #"tell application id "com.googlecode.iterm2" to get tty of current session of current window"#,
    ]

    /// Calls back on the main queue. A terminal is asked over AppleScript off the main queue,
    /// with a time limit; one that cannot be checked (no Automation permission yet, no window)
    /// does not get Return.
    static func shouldSend(to app: NSRunningApplication?, completion: @escaping (Bool) -> Void) {
        let prefs = Preferences.shared
        guard prefs.autoSend, let id = app?.bundleIdentifier else { return completion(false) }
        if prefs.autoSendApps.contains(id) { return completion(true) }
        if id == claudeApp { return completion(true) }
        guard let script = ttyScripts[id] else { return completion(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            let running = runsClaudeCode(script: script)
            DispatchQueue.main.async { completion(running) }
        }
    }

    /// Whether Claude Code is in the foreground of the focused tab, not a shell or a suspended
    /// `claude`: `+` in the process state marks the terminal's foreground process group.
    private static func runsClaudeCode(script: String) -> Bool {
        guard let tty = run("/usr/bin/osascript", ["-e", script])?.trimmingCharacters(in: .whitespacesAndNewlines),
              tty.hasPrefix("/dev/") else {
            Log.write("auto-send: could not get the focused terminal's tty")
            return false
        }
        guard let ps = run("/bin/ps", ["-t", String(tty.dropFirst(5)), "-o", "stat=,command="]) else { return false }
        return ps.split(separator: "\n").contains { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[0].contains("+") else { return false }
            let command = String(fields[1])
            let program = command.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }
            return program == "claude" || command.contains("@anthropic-ai/claude-code/")
        }
    }

    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 1.5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        // The first AppleScript call waits on macOS's Automation prompt; give up rather than hang.
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
