import Foundation

/// The theremin's sound, one sample at a time: a band-limited oscillator
/// with glide, vibrato, a pitch-tracking tone filter and click-free level
/// changes. Pure Swift with no audio framework, so it renders the same
/// bytes every time and can be tested by looking at them.
///
/// The app hands the tracker's reading to `play(frequency:amplitude:)` at
/// the camera's rate (30 Hz) and calls `render` from the audio thread; the
/// per-sample smoothing in between is what turns a 30 Hz control signal
/// into a continuous tone rather than a zipper.
public struct ThereminVoice: Sendable {
    /// The voice's tone settings, mirrored from `ThereminConfig`.
    public struct Tone: Equatable, Sendable {
        public var waveform: ThereminWaveform = .classic
        /// 0…1, see `ThereminConfig.brightness`.
        public var brightness: Double = 0.55
        /// Hz.
        public var vibratoRate: Double = 5.5
        /// Semitones, peak.
        public var vibratoDepth: Double = 0.12
        /// Seconds.
        public var glide: Double = 0.06
        /// 0…1 master level.
        public var volume: Double = 0.8

        public init() {}

        public init(_ config: ThereminConfig) {
            waveform = config.waveform
            brightness = config.brightness
            vibratoRate = config.vibratoRate
            vibratoDepth = config.vibratoDepth
            glide = config.glide
            volume = config.volume
        }
    }

    public let sampleRate: Double
    public var tone = Tone()

    // Targets from the tracker, and the smoothed values that actually play.
    private var targetMidi = 69.0
    private var currentMidi = 69.0
    private var targetAmplitude = 0.0
    private var currentAmplitude = 0.0

    private var phase = 0.0
    private var lfoPhase = 0.0
    private var filter1 = 0.0
    private var filter2 = 0.0

    /// Level smoothing: a fast attack so a note speaks, a slightly slower
    /// release so lifting the volume hand fades rather than snaps.
    private static let attackSeconds = 0.012
    private static let releaseSeconds = 0.025
    /// Below this the release snaps to exact silence (−80 dB: inaudible, and
    /// an exponential tail would otherwise never quite reach zero).
    private static let silenceFloor = 1e-4
    /// Headroom below full scale: the reverb adds on top of this.
    private static let headroom = 0.6

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Whether the voice is producing (or about to produce) sound.
    public var isSilent: Bool {
        targetAmplitude <= 0 && currentAmplitude == 0
    }

    /// The reading to play: a frequency (nil keeps the last one) and a
    /// level in 0…1. Called at the camera's rate.
    public mutating func play(frequency: Double?, amplitude: Double) {
        if let frequency, frequency > 0 {
            targetMidi = MusicTheory.midi(frequency: frequency)
            // From silence, a new note starts where the hand is instead of
            // sliding up from wherever the last one ended.
            if currentAmplitude < 1e-4 { currentMidi = targetMidi }
        }
        targetAmplitude = amplitude.clamped(to: 0...1)
    }

    /// Stops the sound outright (power off): the level snaps to zero,
    /// the filters and phase clear.
    public mutating func reset() {
        targetAmplitude = 0
        currentAmplitude = 0
        phase = 0
        lfoPhase = 0
        filter1 = 0
        filter2 = 0
    }

    /// Renders `count` mono samples into `output`, overwriting.
    public mutating func render(into output: UnsafeMutablePointer<Float>, count: Int) {
        let sr = sampleRate
        let glideCoefficient = 1 - exp(-1 / (max(tone.glide, 0.002) * sr))
        let attack = 1 - exp(-1 / (Self.attackSeconds * sr))
        let release = 1 - exp(-1 / (Self.releaseSeconds * sr))
        let lfoIncrement = tone.vibratoRate / sr
        let depth = tone.vibratoDepth
        // Perceptual master level, with headroom.
        let gain = tone.volume * tone.volume * Self.headroom
        // The tone filter tracks the pitch, so the timbre stays put across
        // the range: ×1.3 the fundamental at its darkest, ×25 wide open.
        let cutoffRatio = 1.3 + 24 * tone.brightness * tone.brightness
        let nyquistCap = sr * 0.45
        let waveform = tone.waveform

        for n in 0..<count {
            currentMidi += (targetMidi - currentMidi) * glideCoefficient
            let vibrato = depth > 0 ? depth * sin(2 * .pi * lfoPhase) : 0
            lfoPhase += lfoIncrement
            if lfoPhase >= 1 { lfoPhase -= 1 }

            let frequency = MusicTheory.frequency(midi: currentMidi + vibrato)
            let increment = frequency / sr
            phase += increment
            if phase >= 1 { phase -= 1 }
            let raw = Self.sample(waveform, phase: phase, increment: increment)

            // Two one-pole stages: a gentle 12 dB/octave roll-off.
            let cutoff = min(frequency * cutoffRatio, nyquistCap)
            let k = 1 - exp(-2 * .pi * cutoff / sr)
            filter1 += (raw - filter1) * k
            filter2 += (filter1 - filter2) * k

            let coefficient = targetAmplitude > currentAmplitude ? attack : release
            currentAmplitude += (targetAmplitude - currentAmplitude) * coefficient
            if targetAmplitude <= 0, currentAmplitude < Self.silenceFloor { currentAmplitude = 0 }

            output[n] = Float(filter2 * currentAmplitude * gain)
        }
    }

    // MARK: - Oscillators

    /// One sample of `waveform` at `phase` (0…1). The sawtooth and square
    /// are band-limited with PolyBLEP, since a naive edge aliases audibly
    /// on a bright setting; the triangle's harmonics fall fast enough on
    /// their own, and the sines have none to alias.
    static func sample(_ waveform: ThereminWaveform, phase: Double, increment: Double) -> Double {
        switch waveform {
        case .sine:
            return sin(2 * .pi * phase)
        case .classic:
            // A tapering harmonic series: the reedy, singing theremin voice.
            let p = 2 * .pi * phase
            let value = sin(p) + 0.42 * sin(2 * p) + 0.2 * sin(3 * p) + 0.08 * sin(4 * p) + 0.04 * sin(5 * p)
            return value / 1.55
        case .triangle:
            return 4 * abs(phase - 0.5) - 1
        case .sawtooth:
            return (2 * phase - 1) - polyBLEP(phase, increment)
        case .square:
            var value = phase < 0.5 ? 1.0 : -1.0
            value += polyBLEP(phase, increment)
            var shifted = phase + 0.5
            if shifted >= 1 { shifted -= 1 }
            value -= polyBLEP(shifted, increment)
            return value
        }
    }

    /// The polynomial band-limited step residual around a discontinuity at
    /// phase 0, for one sample of `dt` per sample.
    static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }
}
