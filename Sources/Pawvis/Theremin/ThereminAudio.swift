import AVFoundation
import Foundation
import PawvisCore
import os

/// The theremin's sound: `ThereminVoice` rendered live by an
/// `AVAudioEngine`, through a reverb, to the default output — plus the
/// recorder that taps the same signal, the player that plays a take back,
/// and the two exporters (MP3 through `MP3Encoder`, WAV through
/// AVFoundation).
///
/// The graph runs at a fixed 48 kHz stereo regardless of the output device:
/// the engine's mixer converts to the device rate, recordings land at a
/// rate MPEG-1 encodes natively, and a headphone swap mid-note changes
/// nothing upstream. The recording tap sits on the reverb's output, so a
/// take is exactly the instrument as heard, and playback (which joins at
/// the mixer) is never recorded over it.
///
/// Everything the audio thread touches lives in `ThereminVoiceBox` behind
/// an unfair lock held for microseconds; the main actor only pokes targets
/// into it and copies the scope out.
final class ThereminAudio {
    static let sampleRate = 48_000.0
    /// The MP3 export bitrate: with no psychoacoustic model, generous.
    static let mp3Bitrate = 256

    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let player = AVAudioPlayerNode()
    private var source: AVAudioSourceNode?
    private let format = AVAudioFormat(standardFormatWithSampleRate: ThereminAudio.sampleRate, channels: 2)!
    let box = ThereminVoiceBox(sampleRate: ThereminAudio.sampleRate)
    private var recorder: TakeRecorder?
    private var configurationObserver: NSObjectProtocol?
    /// Whether the graph should be running (the theremin is on, or a take
    /// is playing); a configuration change restarts it from this.
    private var wantsRunning = false

    /// Called on the main queue when playback of a scheduled take ends.
    var onPlaybackEnded: (() -> Void)?

    init() {
        buildGraph()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // A device change stops the engine; pick up where it left off.
            guard let self, self.wantsRunning else { return }
            _ = self.startEngine()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    private func buildGraph() {
        let source = AVAudioSourceNode(format: format) { [box] _, _, frameCount, audioBufferList -> OSStatus in
            box.render(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        self.source = source
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 0
        engine.attach(source)
        engine.attach(reverb)
        engine.attach(player)
        engine.connect(source, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    // MARK: - Running

    var isRunning: Bool { engine.isRunning }

    /// Starts the graph (a no-op while running). Returns false, with the
    /// reason logged, when the output device refuses.
    @discardableResult
    func start() -> Bool {
        wantsRunning = true
        return startEngine()
    }

    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            Log.app.info("Theremin audio started")
            return true
        } catch {
            Log.app.error("Theremin audio failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Silences the voice and stops the graph once nothing else needs it.
    func stop() {
        wantsRunning = false
        box.reset()
        player.stop()
        if engine.isRunning { engine.stop() }
        Log.app.info("Theremin audio stopped")
    }

    /// Mutes what reaches the speakers without touching the recorded
    /// signal — the demo feed's screenshot mode.
    func setOutputMuted(_ muted: Bool) {
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    // MARK: - The voice

    func play(frequency: Double?, amplitude: Double) {
        box.play(frequency: frequency, amplitude: amplitude)
    }

    func setTone(_ tone: ThereminVoice.Tone, reverbMix: Double) {
        box.setTone(tone)
        // 0…1 maps onto a musical range; fully wet is a bathroom, not a hall.
        reverb.wetDryMix = Float(min(max(reverbMix, 0), 1) * 60)
    }

    // MARK: - Recording

    /// A take in progress: the file, and the running peaks for the strip.
    final class TakeRecorder: @unchecked Sendable {
        let url: URL
        let sampleRate: Double
        private let file: AVAudioFile
        private let lock = NSLock()
        private var frames: Int64 = 0
        private var peaks: [Float] = []
        private var blockPeak: Float = 0
        private var blockFill = 0
        /// One peak every 20 ms.
        private let blockFrames: Int

        init(url: URL, format: AVAudioFormat) throws {
            self.url = url
            sampleRate = format.sampleRate
            blockFrames = Int(format.sampleRate / 50)
            // The processing format's settings carry a non-interleaved flag
            // that files cannot honour (AVAudioFile logs and ignores it);
            // describe the file as what it is, interleaved float.
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }

        func write(_ buffer: AVAudioPCMBuffer) {
            do {
                try file.write(from: buffer)
            } catch {
                Log.app.error("Theremin take write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            let count = Int(buffer.frameLength)
            guard let channels = buffer.floatChannelData else { return }
            let channelCount = Int(buffer.format.channelCount)
            lock.lock()
            frames += Int64(count)
            for i in 0..<count {
                var peak: Float = 0
                for ch in 0..<channelCount { peak = max(peak, abs(channels[ch][i])) }
                blockPeak = max(blockPeak, peak)
                blockFill += 1
                if blockFill >= blockFrames {
                    peaks.append(blockPeak)
                    blockPeak = 0
                    blockFill = 0
                }
            }
            lock.unlock()
        }

        var duration: TimeInterval {
            lock.withLock { Double(frames) / sampleRate }
        }

        func snapshotPeaks() -> [Float] {
            lock.withLock { peaks }
        }
    }

    /// Starts writing the instrument to `url`. The engine must be running.
    func startRecording(to url: URL) throws -> TakeRecorder {
        stopRecording()
        let recorder = try TakeRecorder(url: url, format: format)
        self.recorder = recorder
        reverb.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.write(buffer)
        }
        return recorder
    }

    /// Stops the tap and closes the file; returns the finished take.
    @discardableResult
    func stopRecording() -> TakeRecorder? {
        guard let recorder else { return nil }
        reverb.removeTap(onBus: 0)
        self.recorder = nil
        return recorder
    }

    var isRecording: Bool { recorder != nil }

    // MARK: - Playback

    /// Plays a take from the start; `onPlaybackEnded` fires when it has
    /// actually finished sounding.
    func play(take url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        player.stop()
        guard start() else { return }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.onPlaybackEnded?() }
        }
        player.play()
    }

    func stopPlayback() {
        player.stop()
    }

    var isPlaying: Bool { player.isPlaying }

    // MARK: - Export

    enum ExportError: LocalizedError {
        case empty
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The take is empty."
            case .unreadable(let reason): return "Couldn't read the take: \(reason)"
            }
        }
    }

    /// Encodes the take at `source` to MP3 at `destination`. Blocking; run
    /// it off the main thread. `progress` is called with 0…1 as it goes.
    static func exportMP3(from source: URL, to destination: URL, bitrate: Int = mp3Bitrate,
                          progress: @escaping @Sendable (Double) -> Void) throws {
        let file = try AVAudioFile(forReading: source)
        guard file.length > 0 else { throw ExportError.empty }
        let channels = Int(file.processingFormat.channelCount)
        // The recordings are 48 kHz by construction; anything else (a take
        // from another source) is resampled to it, since MPEG-1 has only
        // three rates.
        let fileRate = Int(file.processingFormat.sampleRate)
        let targetRate = MP3Encoder.supportedSampleRates.contains(fileRate) ? fileRate : 48_000
        let encoder = try MP3Encoder(sampleRate: targetRate, channels: channels, bitrate: bitrate)
        var output = Data()
        let converter: AVAudioConverter?
        let targetFormat: AVAudioFormat
        if targetRate == fileRate {
            converter = nil
            targetFormat = file.processingFormat
        } else {
            targetFormat = AVAudioFormat(standardFormatWithSampleRate: Double(targetRate),
                                         channels: AVAudioChannelCount(channels))!
            converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)
        }
        let chunk: AVAudioFrameCount = 1152 * 8
        let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        let ratio = Double(targetRate) / Double(fileRate)
        let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 64)!
        while file.framePosition < file.length {
            try file.read(into: readBuffer)
            guard readBuffer.frameLength > 0 else { break }
            let pcmBuffer: AVAudioPCMBuffer
            if let converter {
                var consumed = false
                var conversionError: NSError?
                convertedBuffer.frameLength = 0
                converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
                    if consumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return readBuffer
                }
                if let conversionError { throw ExportError.unreadable(conversionError.localizedDescription) }
                pcmBuffer = convertedBuffer
            } else {
                pcmBuffer = readBuffer
            }
            let count = Int(pcmBuffer.frameLength)
            guard count > 0, let data = pcmBuffer.floatChannelData else { continue }
            var pcm: [[Float]] = []
            for ch in 0..<channels {
                pcm.append(Array(UnsafeBufferPointer(start: data[ch], count: count)))
            }
            encoder.append(pcm)
            output.append(encoder.takeOutput())
            progress(Double(file.framePosition) / Double(file.length))
        }
        output.append(encoder.finish())
        try output.write(to: destination, options: .atomic)
        progress(1)
    }

    /// Writes the take at `source` as 24-bit PCM WAV at `destination`.
    /// Blocking; run it off the main thread.
    static func exportWAV(from source: URL, to destination: URL,
                          progress: @escaping @Sendable (Double) -> Void) throws {
        let file = try AVAudioFile(forReading: source)
        guard file.length > 0 else { throw ExportError.empty }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: file.processingFormat.sampleRate,
            AVNumberOfChannelsKey: file.processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: destination)
        let out = try AVAudioFile(forWriting: destination, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try out.write(from: buffer)
            progress(Double(file.framePosition) / Double(file.length))
        }
        progress(1)
    }
}

// MARK: - The audio-thread box

/// Everything the render callback reads and writes, behind one unfair lock:
/// the voice, the oscilloscope ring and the level meter. The lock is held
/// for the length of one render (microseconds) and by main-actor setters
/// for a few stores, so the audio thread never waits on anything slow.
final class ThereminVoiceBox: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var voice: ThereminVoice
    /// Render scratch, sized for the largest hardware buffer.
    private var scratch = [Float](repeating: 0, count: 8192)
    /// The last `scopeLength` samples, as a ring.
    static let scopeLength = 1024
    private var scope = [Float](repeating: 0, count: ThereminVoiceBox.scopeLength)
    private var scopeWrite = 0
    private var peak: Float = 0

    init(sampleRate: Double) {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        voice = ThereminVoice(sampleRate: sampleRate)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func play(frequency: Double?, amplitude: Double) {
        os_unfair_lock_lock(lock)
        voice.play(frequency: frequency, amplitude: amplitude)
        os_unfair_lock_unlock(lock)
    }

    func setTone(_ tone: ThereminVoice.Tone) {
        os_unfair_lock_lock(lock)
        voice.tone = tone
        os_unfair_lock_unlock(lock)
    }

    func reset() {
        os_unfair_lock_lock(lock)
        voice.reset()
        scope = [Float](repeating: 0, count: Self.scopeLength)
        peak = 0
        os_unfair_lock_unlock(lock)
    }

    /// The render callback: mono voice into every output channel.
    func render(frameCount: Int, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        os_unfair_lock_lock(lock)
        var rendered = 0
        while rendered < frameCount {
            let n = min(frameCount - rendered, scratch.count)
            scratch.withUnsafeMutableBufferPointer { s in
                voice.render(into: s.baseAddress!, count: n)
                for i in 0..<n {
                    let v = s[i]
                    scope[scopeWrite] = v
                    scopeWrite = (scopeWrite + 1) % Self.scopeLength
                    let a = abs(v)
                    if a > peak { peak = a }
                }
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    (data + rendered).update(from: s.baseAddress!, count: n)
                }
            }
            rendered += n
        }
        os_unfair_lock_unlock(lock)
    }

    /// A copy of the scope (oldest sample first) and the peak since the
    /// last snapshot, for the stage at its own frame rate.
    func snapshot() -> (scope: [Float], peak: Float) {
        os_unfair_lock_lock(lock)
        var ordered = [Float](repeating: 0, count: Self.scopeLength)
        for i in 0..<Self.scopeLength {
            ordered[i] = scope[(scopeWrite + i) % Self.scopeLength]
        }
        let p = peak
        peak = 0
        os_unfair_lock_unlock(lock)
        return (ordered, p)
    }
}
