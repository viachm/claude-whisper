import AppKit
import AVFoundation
import CoreAudio

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude Whisper.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String) {
        let entry = "\(formatter.string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}

/// The start and stop cues come from the chosen sound set (`<set>-start.wav`, `<set>-stop.wav`,
/// made by tools/make-sounds.py); any other name is a macOS system sound such as "Basso".
enum Sound {
    static func play(_ name: String) {
        guard Preferences.shared.playSounds else { return }
        let set = Preferences.shared.soundSet.rawValue
        switch name {
        case "press": play(file: "\(set)-start")
        case "stop": play(file: "\(set)-stop")
        default: NSSound(named: name)?.play()
        }
    }

    /// Plays a set's start cue, for trying sets in Settings.
    static func preview(_ set: SoundSet) { play(file: "\(set.rawValue)-start") }

    /// Sounds still playing are kept here; an NSSound that nothing holds can be freed and go
    /// silent before it is heard.
    private static var playing: [NSSound] = []

    private static func play(file: String) {
        guard let url = Bundle.main.url(forResource: file, withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            return Log.write("missing sound \(file)")
        }
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.volume = Float(Preferences.shared.soundVolume)
        if !sound.play() { Log.write("could not play \(file)") }
    }
}

/// Whether the default microphone is recording. Claude Code opens it once it is really
/// listening, so this tells a successful start from a press Claude ignored.
enum Microphone {
    static func isRunning() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

/// Hands the text to whichever app has focus: pastes it (optionally pressing Return after, to
/// send a chat message) and puts the previous clipboard back, or only copies it.
enum Paster {
    static func deliver(_ text: String, as action: OutputAction, restoreClipboard: Bool) {
        let board = NSPasteboard.general
        let saved = restoreClipboard && action != .copy ? snapshot(board) : nil
        board.clearContents()
        board.setString(text, forType: .string)
        guard action != .copy else { return }

        press(9, flags: .maskCommand) // V
        if action == .pasteAndReturn { DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay, execute: pressReturn) }
        guard let saved else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    /// How long after the paste Return goes out, so the app has taken the text first.
    static let returnDelay: TimeInterval = 0.08

    static func pressReturn() { press(36, flags: []) }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// The three permissions Claude Whisper needs, for the Settings window to show and link to.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring, microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .microphone: return "Microphone"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: return "Pastes the text into the app you are in."
        case .inputMonitoring: return "Sees the dictation key and the cancel key."
        case .microphone: return "Lets the hidden Claude session hear you."
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// Asks macOS once, which also adds Claude Whisper to the list in System Settings, then opens that
    /// pane, since a refused permission can only be turned on there.
    func openSettings() {
        switch self {
        case .accessibility:
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                return AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)")!)
    }

    private var pane: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .microphone: return "Privacy_Microphone"
        }
    }
}

/// One-time move from the app's old name (Shepit): copies its settings and history, so a rename
/// does not lose them. Runs before anything reads the preferences.
enum Migration {
    static func fromShepit() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromShepit") else { return }
        defer { defaults.set(true, forKey: "migratedFromShepit") }
        if let old = defaults.persistentDomain(forName: "local.viachm.shepit") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            Log.write("migrated \(old.count) settings from Shepit")
        }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let oldHistory = support.appendingPathComponent("Shepit/history.json")
        let newDir = support.appendingPathComponent("Claude Whisper")
        let newHistory = newDir.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: oldHistory.path), !FileManager.default.fileExists(atPath: newHistory.path) {
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: oldHistory, to: newHistory)
        }
    }
}
