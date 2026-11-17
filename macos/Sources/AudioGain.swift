import Accelerate
import AVFoundation
import MediaToolbox

/// Raises a track's volume while it plays. AVAudioMix's own volume only goes down to silence, not
/// above 1, so this is an audio processing tap; loud peaks are softened instead of clipping.
enum AudioGain {
    /// The loudness of a recording's speech (see SpeechLevel), read from its file.
    static func speechLevel(of url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate / 2))
        else { return nil }
        var levels: [Float] = []
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0, let samples = buffer.floatChannelData {
            var rms: Float = 0
            vDSP_rmsqv(samples[0], 1, &rms, vDSP_Length(buffer.frameLength))
            levels.append(rms)
        }
        return SpeechLevel.of(levels)
    }

    /// A tap that multiplies a track's samples by `gain`.
    static func tap(gain: Float) -> MTAudioProcessingTap? {
        let box = Unmanaged.passRetained(Settings(gain: gain))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: box.toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Settings>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let settings = Unmanaged<Settings>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let flags = format.pointee.mFormatFlags
                settings.isFloat = flags & kAudioFormatFlagIsFloat != 0 && format.pointee.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr
                else { return }
                let settings = Unmanaged<Settings>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard settings.isFloat, settings.gain != 1 else { return }
                var gain = settings.gain
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    var count = Int32(buffer.mDataByteSize / 4)
                    vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(count))
                    // tanh leaves speech as it is and rounds off what would clip.
                    if gain > 1 { vvtanhf(data, data, &count) }
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr
        else {
            box.release()
            return nil
        }
        return tap
    }

    private final class Settings {
        let gain: Float
        var isFloat = false
        init(gain: Float) { self.gain = gain }
    }
}
