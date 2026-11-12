import Foundation

/// One `claude -p` call on the user's Claude Code login, for Note Taker's title, summary and
/// questions. Runs in Claude Whisper's own workspace, with the input on standard input; calls back
/// on the main queue with the process's output, or nil when it failed or took too long.
enum NoteClaude {
    static func run(arguments: [String], input: String, directory: URL, timeout: TimeInterval = 180,
                    completion: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Preferences.shared.resolvedClaudePath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        var done = false
        func finish(_ output: String?) {
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                if process.isRunning { process.terminate() }
                completion(output)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !done { Log.write("note taker: claude timed out") }
            finish(nil)
        }
        do {
            try process.run()
        } catch {
            Log.write("note taker: could not start claude: \(error)")
            return finish(nil)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            finish(String(decoding: data, as: UTF8.self))
        }
    }
}
