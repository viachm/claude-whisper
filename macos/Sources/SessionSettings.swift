import Foundation

enum SessionSettings {
    /// Settings layered over the user's own for this session only: voice on, held key, never
    /// submit, and the dictation language when one is chosen in Claude Whisper. Not tap mode: there
    /// the stopping press sends the transcript to Claude as a message, whatever autoSubmit says.
    static func json(language: String) -> String {
        var settings: [String: Any] = ["voice": ["enabled": true, "mode": "hold", "autoSubmit": false]]
        if !language.isEmpty { settings["language"] = language }
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
