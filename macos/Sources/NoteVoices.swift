import FluidAudio
import Foundation

/// Tells the voices in a note's call audio apart on the Mac, with FluidAudio's offline speaker
/// diarization (pyannote segmentation, WeSpeaker voice prints, VBx clustering). Its models, about
/// 22 MB, download once from Hugging Face at a pinned revision, the first time it runs.
enum VoiceSeparation {
    /// Whether the note has call audio to tell voices apart in that `voices` doesn't cover yet.
    static func needed(for note: Note, store: NoteStore) -> Bool {
        guard let recordings = note.recordings, note.voicedRecordings != recordings.count else { return false }
        return recordings.contains { recording in
            recording.speakers.contains(.them)
                && FileManager.default.fileExists(atPath: store.audioFile(note.id, index: recording.index, speaker: .them).path)
        }
    }

    static func voices(of note: Note, store: NoteStore) async throws -> [NoteVoice] {
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        var recordings: [VoiceNumbering.Recording] = []
        for recording in note.recordings ?? [] where recording.speakers.contains(.them) {
            let url = store.audioFile(note.id, index: recording.index, speaker: .them)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let offset = note.audioTime(recording.start)
            let result = try await manager.process(url)
            recordings.append(VoiceNumbering.Recording(
                spans: result.segments.map { (offset + Double($0.startTimeSeconds), offset + Double($0.endTimeSeconds), $0.speakerId) },
                prints: result.speakerDatabase ?? [:]))
        }
        return VoiceNumbering.number(recordings)
    }
}
