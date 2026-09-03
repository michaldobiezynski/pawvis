import Foundation
import XCTest
@testable import PawvisCore

/// The pure half of the theremin: pitch and note maths, the scale magnet,
/// the hand-to-instrument tracker's rules, and the voice's rendered bytes.
final class ThereminTests: XCTestCase {

    // MARK: Music theory

    func testEqualTemperament() {
        XCTAssertEqual(MusicTheory.frequency(midi: 69), 440, accuracy: 1e-9)
        XCTAssertEqual(MusicTheory.frequency(midi: 57), 220, accuracy: 1e-9)
        XCTAssertEqual(MusicTheory.midi(frequency: 880), 81, accuracy: 1e-9)
        XCTAssertEqual(MusicTheory.midi(frequency: MusicTheory.frequency(midi: 61.37)), 61.37, accuracy: 1e-9)
    }

    func testNoteNames() {
        XCTAssertEqual(MusicTheory.noteName(midi: 60), "C4")
        XCTAssertEqual(MusicTheory.noteName(midi: 61), "C♯4")
        XCTAssertEqual(MusicTheory.noteName(midi: 69), "A4")
        XCTAssertEqual(MusicTheory.noteName(midi: 59), "B3")
        XCTAssertEqual(MusicTheory.noteName(midi: 48), "C3")
        let reading = MusicTheory.reading(midi: 69.3)
        XCTAssertEqual(reading.label, "A4")
        XCTAssertEqual(reading.cents, 30)
        XCTAssertEqual(MusicTheory.reading(midi: 68.7).midi, 69)
        XCTAssertEqual(MusicTheory.reading(midi: 68.7).cents, -30)
    }

    /// The magnet: free leaves pitch alone, chromatic rounds, a scale
    /// skips the notes it does not own, and strength scales the pull.
    func testScaleSnapping() {
        XCTAssertEqual(MusicTheory.snap(61.4, scale: .free, key: 0, strength: 1), 61.4)
        XCTAssertEqual(MusicTheory.snap(61.4, scale: .chromatic, key: 0, strength: 1), 61)
        XCTAssertEqual(MusicTheory.snap(61.6, scale: .chromatic, key: 0, strength: 1), 62)
        // C♯ (61) is not in C major: 61.4 is nearer D (62) than C (60).
        XCTAssertEqual(MusicTheory.snap(61.4, scale: .major, key: 0, strength: 1), 62)
        XCTAssertEqual(MusicTheory.snap(60.6, scale: .major, key: 0, strength: 1), 60)
        // In D major, C♯ is a scale note.
        XCTAssertEqual(MusicTheory.snap(61.2, scale: .major, key: 2, strength: 1), 61)
        // Half strength pulls halfway.
        XCTAssertEqual(MusicTheory.snap(61.4, scale: .chromatic, key: 0, strength: 0.5), 61.2, accuracy: 1e-9)
        XCTAssertEqual(MusicTheory.snap(61.4, scale: .chromatic, key: 0, strength: 0), 61.4)
        // Pentatonic in A minor: 71 (B) is not in A minor pentatonic (A C D E G) → 72 (C).
        XCTAssertEqual(MusicTheory.snap(71.3, scale: .pentatonicMinor, key: 9, strength: 1), 72)
        // Every scale owns its key note.
        for scale in ThereminScale.allCases where scale != .free {
            XCTAssertEqual(MusicTheory.snap(62.0, scale: scale, key: 2, strength: 1), 62, "\(scale)")
        }
    }

    // MARK: Config

    func testConfigDecodesTolerantlyAndClamps() throws {
        let json = """
        {"waveform":"sawtooth","brightness":7,"lowNote":10,"octaves":9,"key":14,"nonsense":true,"scale":"major"}
        """
        let config = try JSONDecoder().decode(ThereminConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.waveform, .sawtooth)
        XCTAssertEqual(config.brightness, 1)
        XCTAssertEqual(config.lowNote, ThereminConfig.lowNoteRange.lowerBound)
        XCTAssertEqual(config.octaves, ThereminConfig.octaveRange.upperBound)
        XCTAssertEqual(config.key, 2)
        XCTAssertEqual(config.scale, .major)
        XCTAssertEqual(config.vibratoRate, ThereminConfig().vibratoRate, "untouched fields keep their defaults")

        var settings = PawvisSettings.default
        settings.theremin.scale = .blues
        settings.theremin.layout = .oneHand
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(PawvisSettings.self, from: data), settings)
    }

    // MARK: The tracker

    /// The synthetic hand's palm centre sits a little above and right of
    /// its wrist; place hands by where the palm should land.
    private func hand(palmX: Double, palmY: Double, closed: Bool = false) -> Hand {
        let wrist = Vec2(palmX - 0.0117, palmY + 0.1125)
        let hand = closed ? SyntheticHand.fist(wrist: wrist) : SyntheticHand.openRelaxed(wrist: wrist)
        let palm = HandFeatures(hand: hand)!.palmCenter()!
        XCTAssertEqual(palm.x, palmX, accuracy: 0.002)
        XCTAssertEqual(palm.y, palmY, accuracy: 0.002)
        return hand
    }

    private func tracker(_ configure: (inout ThereminConfig) -> Void = { _ in }) -> ThereminTracker {
        var config = ThereminConfig()
        config.scale = .free
        configure(&config)
        return ThereminTracker(config: config, mirror: false)
    }

    func testRightMostHandPlaysPitchAndTheOtherVolume() {
        var t = tracker()
        let reading = t.update(hands: [hand(palmX: 0.3, palmY: 0.5), hand(palmX: 0.8, palmY: 0.5)], at: 0)
        XCTAssertEqual(reading.hands.map(\.role), [.pitch, .volume])
        XCTAssertEqual(reading.hands[0].palm.x, 0.8, accuracy: 0.01)
        XCTAssertEqual(reading.hands[1].palm.x, 0.3, accuracy: 0.01)
        XCTAssertNotNil(reading.frequency)
        XCTAssertTrue(reading.isSounding)
    }

    /// The pitch zone maps its left edge to the low note and its right edge
    /// (the antenna) to the top note, linearly in semitones.
    func testPitchZoneMapsToTheConfiguredRange() {
        var t = tracker { $0.lowNote = 48; $0.octaves = 3 }
        let zone = ThereminTracker.pitchZone
        let low = t.update(hands: [hand(palmX: zone.lowerBound, palmY: 0.5)], at: 0)
        XCTAssertEqual(low.midi!, 48, accuracy: 0.15)
        XCTAssertEqual(low.pitchPosition!, 0, accuracy: 0.01)
        t.reset()
        let high = t.update(hands: [hand(palmX: zone.upperBound + 0.05, palmY: 0.5)], at: 0)
        XCTAssertEqual(high.midi!, 84, accuracy: 0.01, "past the antenna clamps to the top note")
        t.reset()
        let mid = t.update(hands: [hand(palmX: (zone.lowerBound + zone.upperBound) / 2, palmY: 0.5)], at: 0)
        XCTAssertEqual(mid.midi!, 66, accuracy: 0.15)
        XCTAssertEqual(mid.frequency!, MusicTheory.frequency(midi: mid.midi!), accuracy: 1e-9)
        XCTAssertEqual(mid.note?.label, MusicTheory.reading(midi: mid.midi!).label)
    }

    /// A lone hand plays at full volume: the instrument speaks at once.
    func testALoneHandSoundsAtFullVolume() {
        var t = tracker()
        let reading = t.update(hands: [hand(palmX: 0.7, palmY: 0.5)], at: 0)
        XCTAssertEqual(reading.hands.map(\.role), [.pitch])
        XCTAssertEqual(reading.amplitude, 1)
        XCTAssertNil(reading.volumePosition)
    }

    /// The volume hand's height is the level: silent at the loop, full at
    /// the top, squared in between.
    func testVolumeHandHeightSetsTheLevel() {
        var t = tracker()
        let zone = ThereminTracker.volumeZone
        let pitch = hand(palmX: 0.8, palmY: 0.5)
        let silent = t.update(hands: [pitch, hand(palmX: 0.25, palmY: zone.upperBound + 0.02)], at: 0)
        XCTAssertEqual(silent.amplitude, 0)
        XCTAssertEqual(silent.volumePosition!, 0, accuracy: 0.01)
        XCTAssertFalse(silent.isSounding)
        t.reset()
        let loud = t.update(hands: [pitch, hand(palmX: 0.25, palmY: zone.lowerBound - 0.02)], at: 0)
        XCTAssertEqual(loud.amplitude, 1, accuracy: 0.01)
        t.reset()
        let middle = zone.lowerBound + (zone.upperBound - zone.lowerBound) / 2
        let half = t.update(hands: [pitch, hand(palmX: 0.25, palmY: middle)], at: 0)
        XCTAssertEqual(half.volumePosition!, 0.5, accuracy: 0.02)
        XCTAssertEqual(half.amplitude, 0.25, accuracy: 0.03)
    }

    /// Losing the volume hand holds the last level; losing both hands
    /// resets it to full for the next phrase.
    func testAbsentVolumeHandHoldsTheLastLevel() {
        var t = tracker()
        let zone = ThereminTracker.volumeZone
        let pitch = hand(palmX: 0.8, palmY: 0.5)
        let low = zone.upperBound - 0.1 // near the loop: quiet
        var time = 0.0
        var quiet = ThereminReading()
        for _ in 0..<5 {
            quiet = t.update(hands: [pitch, hand(palmX: 0.25, palmY: low)], at: time)
            time += 1 / 30
        }
        XCTAssertGreaterThan(quiet.amplitude, 0)
        XCTAssertLessThan(quiet.amplitude, 0.1)
        // Volume hand leaves: the level stays where it was, no jump to full.
        let held = t.update(hands: [pitch], at: time)
        XCTAssertEqual(held.amplitude, quiet.amplitude, accuracy: 0.02)
        XCTAssertEqual(held.hands.map(\.role), [.pitch])
        // Both hands leave, then a lone hand returns: full volume again.
        time += 1
        let gone = t.update(hands: [], at: time)
        XCTAssertEqual(gone.amplitude, 0)
        time += 1
        XCTAssertEqual(t.update(hands: [pitch], at: time).amplitude, 1)
    }

    /// A one- or two-frame Vision dropout must not stutter the note.
    func testTrackingLossGraceHoldsTheNote() {
        var t = tracker()
        let sounding = t.update(hands: [hand(palmX: 0.7, palmY: 0.5)], at: 0)
        let dropped = t.update(hands: [], at: 0.1)
        XCTAssertTrue(dropped.isSounding)
        XCTAssertEqual(dropped.frequency, sounding.frequency)
        XCTAssertTrue(dropped.hands.isEmpty, "nothing is drawn for a hand that is not there")
        let gone = t.update(hands: [], at: 0.1 + ThereminTracker.trackingLossGrace + 0.05)
        XCTAssertFalse(gone.isSounding)
        XCTAssertNil(gone.frequency)
    }

    /// The mirror setting flips the view, so with a mirrored camera the
    /// player's right hand (on the camera's left) is the pitch hand.
    func testMirroringFlipsTheView() {
        var mirrored = ThereminTracker(config: ThereminConfig(), mirror: true)
        let reading = mirrored.update(hands: [hand(palmX: 0.2, palmY: 0.5), hand(palmX: 0.7, palmY: 0.5)], at: 0)
        XCTAssertEqual(reading.hands[0].role, .pitch)
        XCTAssertEqual(reading.hands[0].palm.x, 0.8, accuracy: 0.01, "camera x 0.2 is view x 0.8")
        XCTAssertEqual(reading.hands[1].palm.x, 0.3, accuracy: 0.01)
    }

    /// One-hand layout: the same hand's height is the volume, and no
    /// volume hand is drawn.
    func testOneHandLayoutUsesHeightForVolume() {
        var t = tracker { $0.layout = .oneHand }
        let zone = ThereminTracker.volumeZone
        let top = t.update(hands: [hand(palmX: 0.7, palmY: zone.lowerBound)], at: 0)
        XCTAssertEqual(top.amplitude, 1, accuracy: 0.01)
        XCTAssertEqual(top.hands.map(\.role), [.pitch])
        t.reset()
        let bottom = t.update(hands: [hand(palmX: 0.7, palmY: zone.upperBound)], at: 0)
        XCTAssertEqual(bottom.amplitude, 0)
        // A second hand is ignored, not made the volume hand.
        t.reset()
        let two = t.update(hands: [hand(palmX: 0.7, palmY: zone.lowerBound), hand(palmX: 0.2, palmY: zone.upperBound)], at: 0)
        XCTAssertEqual(two.amplitude, 1, accuracy: 0.01)
        XCTAssertEqual(two.hands.count, 1)
    }

    /// The fist mute cuts the sound after two closed frames and is off
    /// unless the setting asks for it.
    func testFistMutesWhenEnabled() {
        let fist = hand(palmX: 0.25, palmY: 0.4, closed: true)
        XCTAssertTrue(HandFeatures(hand: fist)!.isClosedHand(), "the synthetic fist must read as closed")
        let pitch = hand(palmX: 0.8, palmY: 0.5)

        var off = tracker()
        _ = off.update(hands: [pitch, fist], at: 0)
        let offReading = off.update(hands: [pitch, fist], at: 1 / 30)
        XCTAssertFalse(offReading.muted)
        XCTAssertGreaterThan(offReading.amplitude, 0)

        var on = tracker { $0.fistMutes = true }
        let first = on.update(hands: [pitch, fist], at: 0)
        XCTAssertFalse(first.muted, "one frame is not a fist")
        let second = on.update(hands: [pitch, fist], at: 1 / 30)
        XCTAssertTrue(second.muted)
        XCTAssertEqual(second.amplitude, 0)
        XCTAssertTrue(second.hands[1].closed)
        let opened = on.update(hands: [pitch, hand(palmX: 0.25, palmY: 0.4)], at: 2 / 30)
        XCTAssertFalse(opened.muted)
        XCTAssertGreaterThan(opened.amplitude, 0)
    }

    /// Scale snapping reaches the reading: with a hard major magnet every
    /// pitch across the zone lands on a scale note.
    func testSnappedReadingsLandOnScaleNotes() {
        var t = tracker { $0.scale = .major; $0.key = 0; $0.snapStrength = 1 }
        let zone = ThereminTracker.pitchZone
        let majorDegrees: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
        for step in 0...20 {
            t.reset()
            let x = zone.lowerBound + (zone.upperBound - zone.lowerBound) * Double(step) / 20
            let reading = t.update(hands: [hand(palmX: x, palmY: 0.5)], at: 0)
            let midi = reading.midi!
            XCTAssertEqual(midi, midi.rounded(), accuracy: 1e-9)
            XCTAssertTrue(majorDegrees.contains(Int(midi.rounded()) % 12), "\(midi) is not in C major")
            XCTAssertEqual(reading.note?.cents, 0)
        }
    }

    // MARK: The voice

    private func render(_ voice: inout ThereminVoice, seconds: Double) -> [Float] {
        let count = Int(seconds * voice.sampleRate)
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            // In slices, as the audio thread would.
            var offset = 0
            while offset < count {
                let n = min(512, count - offset)
                voice.render(into: buffer.baseAddress! + offset, count: n)
                offset += n
            }
        }
        return out
    }

    private func zeroCrossings(_ samples: ArraySlice<Float>) -> Int {
        var crossings = 0
        var previous = samples.first ?? 0
        for s in samples.dropFirst() {
            if (previous < 0 && s >= 0) || (previous >= 0 && s < 0) { crossings += 1 }
            previous = s
        }
        return crossings
    }

    /// A sine at 440 Hz renders at 440 Hz: 880 zero crossings a second,
    /// once the onset has settled.
    func testSineRendersAtThePlayedFrequency() {
        var voice = ThereminVoice(sampleRate: 48_000)
        voice.tone.waveform = .sine
        voice.tone.vibratoDepth = 0
        voice.tone.brightness = 1
        voice.play(frequency: 440, amplitude: 1)
        let samples = render(&voice, seconds: 2)
        let second = samples[48_000...]
        XCTAssertEqual(zeroCrossings(second), 880, accuracy: 3)
        let peak = second.map { abs($0) }.max()!
        XCTAssertGreaterThan(peak, 0.2)
        XCTAssertLessThanOrEqual(peak, 1)
    }

    /// Glide slides the pitch rather than jumping it, and a note begun from
    /// silence starts on the hand, not on the old pitch.
    func testGlideAndFreshStart() {
        var voice = ThereminVoice(sampleRate: 48_000)
        voice.tone.waveform = .sine
        voice.tone.vibratoDepth = 0
        voice.tone.glide = 0.3
        voice.play(frequency: 220, amplitude: 1)
        _ = render(&voice, seconds: 1)
        voice.play(frequency: 440, amplitude: 1)
        let sliding = render(&voice, seconds: 0.1)
        // 100 ms into a 300 ms glide the pitch is still well short of 440.
        let crossings = zeroCrossings(sliding[...])
        XCTAssertGreaterThan(crossings, 44)
        XCTAssertLessThan(crossings, 80)
        // Silence, then a new note: no slide from 440 down to 110.
        voice.play(frequency: nil, amplitude: 0)
        _ = render(&voice, seconds: 0.5)
        voice.play(frequency: 110, amplitude: 1)
        let fresh = render(&voice, seconds: 1)
        XCTAssertEqual(zeroCrossings(fresh[24_000...]), 110, accuracy: 3)
    }

    /// Level changes are smoothed: the largest sample-to-sample step during
    /// the onset is no bigger than the tone's own steady-state slope (a
    /// bright sawtooth has a big one of its own — that is the waveform, not
    /// a click), and after the release silence really is zero.
    func testOnsetAndReleaseAreClickFree() {
        for waveform in ThereminWaveform.allCases {
            var voice = ThereminVoice(sampleRate: 48_000)
            voice.tone.waveform = waveform
            voice.tone.brightness = 0.6
            voice.play(frequency: 330, amplitude: 1)
            let samples = render(&voice, seconds: 0.6)
            func maxStep(_ slice: ArraySlice<Float>) -> Float {
                var step: Float = 0
                var previous = slice.first ?? 0
                for s in slice.dropFirst() {
                    step = max(step, abs(s - previous))
                    previous = s
                }
                return step
            }
            let onset = maxStep(samples[0..<9600])
            let steady = maxStep(samples[19_200...]) // 0.4 s in: long past the attack
            XCTAssertLessThanOrEqual(onset, steady * 1.02 + 0.002, "\(waveform) clicks at onset")
            XCTAssertTrue(samples.allSatisfy { abs($0) <= 1 }, "\(waveform) exceeds full scale")
            voice.play(frequency: nil, amplitude: 0)
            let release = render(&voice, seconds: 0.3)
            XCTAssertLessThanOrEqual(maxStep(release[...]), steady * 1.02 + 0.002, "\(waveform) clicks at release")
            XCTAssertTrue(voice.isSilent, "\(waveform) is not silent after the release")
            let tail = render(&voice, seconds: 0.05)
            XCTAssertTrue(tail.allSatisfy { $0 == 0 }, "\(waveform) does not fall silent")
        }
    }

    /// Vibrato moves the pitch: the crossing count over a cycle stays put
    /// while the instantaneous pitch swings.
    func testVibratoSwingsThePitch() {
        var voice = ThereminVoice(sampleRate: 48_000)
        voice.tone.waveform = .sine
        voice.tone.vibratoRate = 2
        voice.tone.vibratoDepth = 2 // ±2 semitones: an obvious swing
        voice.play(frequency: 440, amplitude: 1)
        _ = render(&voice, seconds: 0.5)
        // Quarter-cycle windows of a 2 Hz vibrato: the two halves differ.
        let samples = render(&voice, seconds: 0.5)
        let up = zeroCrossings(samples[0..<12_000])
        let down = zeroCrossings(samples[12_000..<24_000])
        XCTAssertNotEqual(up, down)
        XCTAssertGreaterThan(abs(up - down), 8)
    }

    func testPolyBLEPIsZeroAwayFromTheEdge() {
        XCTAssertEqual(ThereminVoice.polyBLEP(0.5, 0.01), 0)
        XCTAssertNotEqual(ThereminVoice.polyBLEP(0.005, 0.01), 0)
        XCTAssertNotEqual(ThereminVoice.polyBLEP(0.995, 0.01), 0)
        // The sawtooth's mean over a cycle is ~0 and it stays in range.
        let steps = 1000
        var mean = 0.0
        for i in 0..<steps {
            let v = ThereminVoice.sample(.sawtooth, phase: Double(i) / Double(steps), increment: 0.01)
            XCTAssertLessThanOrEqual(abs(v), 1.05)
            mean += v
        }
        XCTAssertEqual(mean / Double(steps), 0, accuracy: 0.02)
    }
}
