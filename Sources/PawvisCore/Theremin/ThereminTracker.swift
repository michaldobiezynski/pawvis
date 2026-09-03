import Foundation

/// A hand's part in the instrument.
public enum ThereminRole: String, Equatable, Sendable {
    case pitch
    case volume
}

/// One tracked hand, in *view* space: 0…1 with the origin top-left, and
/// mirrored when the camera is, so a hand moving toward the pitch antenna
/// on the player's right moves right on the stage.
public struct ThereminHandMark: Equatable, Sendable {
    public var role: ThereminRole
    public var palm: Vec2
    public var fingertips: [Vec2]
    /// Closed into a fist (the mute gesture) this frame.
    public var closed: Bool

    public init(role: ThereminRole, palm: Vec2, fingertips: [Vec2], closed: Bool) {
        self.role = role
        self.palm = palm
        self.fingertips = fingertips
        self.closed = closed
    }
}

/// What the instrument should sound like right now, plus what to draw.
public struct ThereminReading: Equatable, Sendable {
    public var hands: [ThereminHandMark] = []
    /// 0…1 across the pitch zone (left edge = low note), nil with no pitch hand.
    public var pitchPosition: Double?
    /// 0…1 up the volume zone (bottom = silent), nil with no volume hand.
    public var volumePosition: Double?
    /// The pitch being played as a fractional MIDI note, after the scale
    /// magnet; nil when nothing sounds.
    public var midi: Double?
    /// Hz of `midi`.
    public var frequency: Double?
    /// 0…1: the level the voice should play at (0 = silence).
    public var amplitude: Double = 0
    /// The fist mute is engaged.
    public var muted = false
    /// The nearest note to `midi`, for the tuner.
    public var note: NoteReading?

    public init() {}

    public var isSounding: Bool { amplitude > 0 && frequency != nil }
}

/// Turns tracked hands into a theremin reading, frame by frame.
///
/// The layout is the real instrument's: the pitch antenna stands at the
/// right edge of the view, and the pitch hand's *distance to it* is the
/// pitch — nearer is higher, mapped so equal hand travel is an equal
/// interval (the "linear" response of a good modern theremin, and the one
/// that can be learned). The volume loop lies at the bottom left: the
/// volume hand's height above it is the loudness, silent at the loop.
///
/// Rules a player leans on, each deliberate:
///
/// - **The right-most hand is the pitch hand.** Vision's chirality is not
///   trusted for this (it flips under mirroring and on hands seen edge-on);
///   position is what a theremin itself goes by. When two hands cross, the
///   one nearer where the pitch hand just was keeps the role.
/// - **No volume hand means the last level holds, full at first.** A lone
///   hand sounds at once (the instrument is discoverable), and a volume
///   hand that drops out of frame at the loop does not make the note jump
///   to full — it leaves the level where it was. Both hands gone resets it.
/// - **A pitch hand that flickers out for a frame or two holds the note.**
///   Vision drops a hand now and then; a tracking-loss grace keeps that
///   from stuttering the tone. Past the grace the sound stops.
/// - **Palm, not fingertip.** The palm barely moves when fingers do, so
///   pitch does not wobble with a twitch; smoothing is a One Euro filter,
///   the same as the cursor's.
public struct ThereminTracker: Sendable {
    public var config: ThereminConfig
    /// Mirror the camera (a user-facing webcam), as the rest of Pawvis does.
    public var mirror: Bool

    /// The pitch zone across the view: the low note at its left edge, the
    /// high note at its right, where the antenna stands.
    public static let pitchZone = 0.42...0.92
    /// The volume zone up the view: silent at the bottom, full at the top.
    public static let volumeZone = 0.16...0.86
    /// Frames the pitch hand may vanish for before the note stops.
    public static let trackingLossGrace: TimeInterval = 0.25
    /// A pitch hand steadier than this per frame does not re-smooth: the
    /// filters below do the fine work.
    private static let minJointConfidence = 0.2

    private var pitchFilter = OneEuroFilter2D(params: .init(minCutoff: 1.1, beta: 0.02, dCutoff: 1.0))
    private var volumeFilter = OneEuroFilter2D(params: .init(minCutoff: 1.4, beta: 0.02, dCutoff: 1.0))
    private var lastPitchPalm: Vec2?
    private var lastPitchTime: TimeInterval = -.greatestFiniteMagnitude
    private var lastReading = ThereminReading()
    /// The level the volume hand last set; full until one is seen.
    private var heldVolume: Double = 1
    private var fistFrames = 0

    public init(config: ThereminConfig, mirror: Bool) {
        self.config = config
        self.mirror = mirror
    }

    public mutating func reset() {
        pitchFilter.reset()
        volumeFilter.reset()
        lastPitchPalm = nil
        lastPitchTime = -.greatestFiniteMagnitude
        lastReading = ThereminReading()
        heldVolume = 1
        fistFrames = 0
    }

    /// One camera frame of raw (camera-space) hands.
    public mutating func update(hands: [Hand], at time: TimeInterval) -> ThereminReading {
        // View-space palms, with the fingertips for drawing.
        struct Seen {
            var palm: Vec2
            var tips: [Vec2]
            var closed: Bool
        }
        var seen: [Seen] = []
        for hand in hands {
            guard let features = HandFeatures(hand: hand, minJointConfidence: Self.minJointConfidence),
                  let palm = features.palmCenter() else { continue }
            let tips = hand.fingertips.map { view($0.point) }
            seen.append(Seen(palm: view(palm), tips: tips, closed: features.isClosedHand()))
        }
        // Right-most first. Two hands within a whisker of each other keep
        // their roles by continuity rather than by a coin toss.
        seen.sort { $0.palm.x > $1.palm.x }
        if seen.count >= 2, abs(seen[0].palm.x - seen[1].palm.x) < 0.06, let previous = lastPitchPalm,
           seen[1].palm.distance(to: previous) < seen[0].palm.distance(to: previous) {
            seen.swapAt(0, 1)
        }

        var reading = ThereminReading()
        let pitchHand = seen.first
        let volumeHand: Seen?
        switch config.layout {
        case .twoHands: volumeHand = seen.count >= 2 ? seen[1] : nil
        case .oneHand: volumeHand = pitchHand
        }

        if let pitchHand {
            let palm = pitchFilter.filter(pitchHand.palm, at: time)
            lastPitchPalm = palm
            lastPitchTime = time
            reading.hands.append(ThereminHandMark(role: .pitch, palm: palm, fingertips: pitchHand.tips,
                                                  closed: pitchHand.closed))
            let position = Self.unit(palm.x, in: Self.pitchZone)
            reading.pitchPosition = position
            let raw = Double(config.lowNote) + Double(config.octaves * 12) * position
            let midi = MusicTheory.snap(raw, scale: config.scale, key: config.key, strength: config.snapStrength)
            reading.midi = midi
            reading.frequency = MusicTheory.frequency(midi: midi)
            reading.note = MusicTheory.reading(midi: midi)
        } else {
            pitchFilter.reset()
        }

        var closed = false
        if let volumeHand {
            let palm = config.layout == .oneHand
                ? (reading.hands.first?.palm ?? volumeHand.palm)
                : volumeFilter.filter(volumeHand.palm, at: time)
            if config.layout == .twoHands {
                reading.hands.append(ThereminHandMark(role: .volume, palm: palm, fingertips: volumeHand.tips,
                                                      closed: volumeHand.closed))
            }
            let position = Self.unit(Self.volumeZone.upperBound - palm.y + Self.volumeZone.lowerBound,
                                     in: Self.volumeZone)
            reading.volumePosition = position
            heldVolume = Self.level(for: position)
            closed = volumeHand.closed
        } else {
            volumeFilter.reset()
        }

        // The mute: a fist held for two frames cuts the sound; one open
        // frame restores it.
        if config.fistMutes, closed {
            fistFrames += 1
        } else {
            fistFrames = 0
        }
        reading.muted = config.fistMutes && fistFrames >= 2

        if pitchHand != nil {
            reading.amplitude = reading.muted ? 0 : heldVolume
        } else if time - lastPitchTime < Self.trackingLossGrace, lastReading.isSounding {
            // A dropped frame: keep sounding the last note, but draw nothing.
            reading.pitchPosition = lastReading.pitchPosition
            reading.volumePosition = lastReading.volumePosition
            reading.midi = lastReading.midi
            reading.frequency = lastReading.frequency
            reading.note = lastReading.note
            reading.amplitude = lastReading.muted ? 0 : heldVolume
            reading.muted = lastReading.muted
        } else {
            // Both hands gone for good: the next note starts at full.
            reading.amplitude = 0
            if seen.isEmpty { heldVolume = 1 }
        }

        lastReading = reading
        return reading
    }

    /// Camera space → view space (mirrored for a user-facing camera).
    private func view(_ point: Vec2) -> Vec2 {
        mirror ? Vec2(1 - point.x, point.y) : point
    }

    /// Where `value` sits in `range`, clamped to 0…1.
    static func unit(_ value: Double, in range: ClosedRange<Double>) -> Double {
        ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    /// The volume hand's height as a level: a squared curve, so the quiet
    /// end has room to be expressive, with a dead band at the loop so a
    /// hand resting there is truly silent.
    static func level(for position: Double) -> Double {
        guard position > 0.03 else { return 0 }
        return position * position
    }
}
