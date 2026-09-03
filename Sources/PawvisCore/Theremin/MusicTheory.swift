import Foundation

/// A pitch, read as a note: the name and octave of the nearest note and how
/// far off it the pitch sits, for the tuner readout.
public struct NoteReading: Equatable, Sendable {
    /// e.g. "A", "C♯".
    public var name: String
    /// Scientific pitch notation octave: A4 is 440 Hz.
    public var octave: Int
    /// The nearest note's MIDI number.
    public var midi: Int
    /// −50…50: how far the pitch sits from that note.
    public var cents: Int

    public var label: String { "\(name)\(octave)" }

    public init(name: String, octave: Int, midi: Int, cents: Int) {
        self.name = name
        self.octave = octave
        self.midi = midi
        self.cents = cents
    }
}

/// Equal temperament, A4 = 440 Hz, and the scale magnet the theremin uses.
public enum MusicTheory {
    public static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Frequency of a (fractional) MIDI note.
    public static func frequency(midi: Double) -> Double {
        440 * pow(2, (midi - 69) / 12)
    }

    /// The (fractional) MIDI note of a frequency.
    public static func midi(frequency: Double) -> Double {
        69 + 12 * log2(frequency / 440)
    }

    /// "A4", "C♯3"… for a MIDI note number.
    public static func noteName(midi: Int) -> String {
        let reading = reading(midi: Double(midi))
        return reading.label
    }

    /// The nearest note to a fractional MIDI pitch and the offset from it.
    public static func reading(midi: Double) -> NoteReading {
        let nearest = Int(midi.rounded())
        let cents = Int(((midi - Double(nearest)) * 100).rounded())
        let index = ((nearest % 12) + 12) % 12
        // MIDI 60 is C4, so the octave is (note / 12) − 1.
        let octave = Int((Double(nearest) / 12).rounded(.down)) - 1
        return NoteReading(name: noteNames[index], octave: octave, midi: nearest, cents: cents)
    }

    /// Pulls a fractional MIDI pitch toward the nearest note of `scale` in
    /// `key`, by `strength` (0 leaves it alone, 1 lands on the note). Free
    /// scale returns the pitch unchanged.
    public static func snap(_ midi: Double, scale: ThereminScale, key: Int, strength: Double) -> Double {
        guard let intervals = scale.intervals, strength > 0 else { return midi }
        let k = ((key % 12) + 12) % 12
        // Nearest scale note: check the octave around the pitch.
        let base = Int(midi.rounded(.down))
        var best = Double(base)
        var bestDistance = Double.infinity
        for candidate in (base - 12)...(base + 12) {
            let degree = (((candidate - k) % 12) + 12) % 12
            guard intervals.contains(degree) else { continue }
            let distance = abs(Double(candidate) - midi)
            if distance < bestDistance {
                bestDistance = distance
                best = Double(candidate)
            }
        }
        let s = strength.clamped(to: 0...1)
        return midi + (best - midi) * s
    }
}
