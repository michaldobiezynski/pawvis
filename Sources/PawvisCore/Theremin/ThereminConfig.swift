import Foundation

/// The theremin's voice: what the oscillator plays before the tone filter.
public enum ThereminWaveform: String, Codable, CaseIterable, Sendable {
    /// A sine with a tapering run of harmonics — the vocal, cello-like
    /// timbre of the instrument itself.
    case classic
    case sine
    case triangle
    case sawtooth
    case square

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .sawtooth: return "Sawtooth"
        case .square: return "Square"
        }
    }
}

/// Which hands play. The classic layout is the instrument's own: the pitch
/// hand at the antenna on the right, the volume hand over the loop on the
/// left. One-hand lets a single hand carry both, height for volume.
public enum ThereminLayout: String, Codable, CaseIterable, Sendable {
    case twoHands
    case oneHand

    public var displayName: String {
        switch self {
        case .twoHands: return "Two hands (classic)"
        case .oneHand: return "One hand"
        }
    }
}

/// The scale the pitch may be pulled toward. `free` is the real
/// instrument — every pitch in between the notes is playable — and the
/// rest exist because a theremin is famously hard to play in tune.
public enum ThereminScale: String, Codable, CaseIterable, Sendable {
    case free
    case chromatic
    case major
    case minor
    case pentatonicMajor
    case pentatonicMinor
    case blues
    case wholeTone

    public var displayName: String {
        switch self {
        case .free: return "Off (continuous)"
        case .chromatic: return "Chromatic"
        case .major: return "Major"
        case .minor: return "Natural minor"
        case .pentatonicMajor: return "Major pentatonic"
        case .pentatonicMinor: return "Minor pentatonic"
        case .blues: return "Blues"
        case .wholeTone: return "Whole tone"
        }
    }

    /// Scale degrees as semitones above the key, or nil for no snapping.
    public var intervals: [Int]? {
        switch self {
        case .free: return nil
        case .chromatic: return Array(0..<12)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .pentatonicMajor: return [0, 2, 4, 7, 9]
        case .pentatonicMinor: return [0, 3, 5, 7, 10]
        case .blues: return [0, 3, 5, 6, 7, 10]
        case .wholeTone: return [0, 2, 4, 6, 8, 10]
        }
    }
}

/// Everything about the theremin a player would want remembered between
/// sessions: the voice, the range, the scale help, and which hands play.
/// Lives in the settings tree (`PawvisSettings.theremin`) and decodes
/// field-tolerantly like every other section, so a build that adds a knob
/// never resets the ones before it.
public struct ThereminConfig: Codable, Equatable, Sendable {
    public var waveform: ThereminWaveform = .classic
    /// 0…1: the tone filter, from little more than the fundamental to wide open.
    public var brightness: Double = 0.55
    /// Vibrato LFO rate in Hz.
    public var vibratoRate: Double = 5.5
    /// Vibrato depth in semitones (peak); 0 is off.
    public var vibratoDepth: Double = 0.12
    /// 0…1: reverb wet mix.
    public var reverb: Double = 0.28
    /// 0…1: the master level.
    public var volume: Double = 0.8
    /// Portamento time constant in seconds: how quickly the pitch follows
    /// the hand. Small is direct, large is a slide.
    public var glide: Double = 0.06

    /// MIDI note number of the low end of the pitch zone (C3 = 48).
    public var lowNote: Int = 48
    /// How many octaves the pitch zone spans.
    public var octaves: Int = 3
    public var scale: ThereminScale = .free
    /// The key for the scale, 0 = C … 11 = B.
    public var key: Int = 0
    /// 0…1: how hard the pitch is pulled to the nearest scale note. 1 snaps
    /// outright; in between, notes act as magnets and glides stay possible.
    public var snapStrength: Double = 0.75

    public var layout: ThereminLayout = .twoHands
    /// Close the volume hand into a fist to cut the sound — staccato the
    /// real instrument cannot do. Off by default: a misread fist would cut a
    /// held note.
    public var fistMutes: Bool = false
    /// Show the camera behind the instrument, so the zones can be found.
    public var showCamera: Bool = true

    public init() {}

    /// The MIDI note at the top of the pitch zone.
    public var highNote: Int { lowNote + octaves * 12 }

    public static let lowNoteRange = 24...72   // C1 … C5
    public static let octaveRange = 1...5

    enum CodingKeys: String, CodingKey {
        case waveform, brightness, vibratoRate, vibratoDepth, reverb, volume, glide
        case lowNote, octaves, scale, key, snapStrength
        case layout, fistMutes, showCamera
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(ThereminWaveform.self, forKey: .waveform) { waveform = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .brightness) { brightness = v.clamped(to: 0...1) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .vibratoRate) { vibratoRate = v.clamped(to: 0.5...12) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .vibratoDepth) { vibratoDepth = v.clamped(to: 0...1) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .reverb) { reverb = v.clamped(to: 0...1) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .volume) { volume = v.clamped(to: 0...1) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .glide) { glide = v.clamped(to: 0...1) }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .lowNote) { lowNote = v.clamped(to: Self.lowNoteRange) }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .octaves) { octaves = v.clamped(to: Self.octaveRange) }
        if let v = try? c.decodeIfPresent(ThereminScale.self, forKey: .scale) { scale = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .key) { key = ((v % 12) + 12) % 12 }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .snapStrength) { snapStrength = v.clamped(to: 0...1) }
        if let v = try? c.decodeIfPresent(ThereminLayout.self, forKey: .layout) { layout = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .fistMutes) { fistMutes = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showCamera) { showCamera = v }
    }
}
