import Foundation
import PawvisCore

/// The camera-queue face of the pure `AttentionGate` policy, mirroring
/// `FrameThrottleBox`: the state machine under one lock, with the
/// main-actor facts it needs (the tuning, a press or scroll in flight, the
/// camera borrowed by a window) mirrored in so the tap can consult them off-main.
///
/// The tap calls `assess` for every frame that passed the idle throttle; a
/// frame answered `false` skips hand-pose inference entirely and never
/// reaches the gesture engine — while the user faces away, the only Vision
/// work left is the (much cheaper) face detector, sampled one frame in
/// `observationStride`. The gate holds its verdict between samples; its
/// hysteresis is time-based, so sparse observations are all it needs.
final class AttentionGateBox: @unchecked Sendable {
    /// Face detection runs on one frame in this many (~10 Hz of the locked
    /// 30 fps feed): heads turn on human time, and the gate's away/return
    /// delays are an order of magnitude above the sampling gap.
    static let observationStride = 3

    private let lock = NSLock()
    private var gate = AttentionGate()
    /// A button held or a scroll active: the gate must never close mid-press.
    private var interacting = false
    /// A window (the trainer, the theremin) owns the stream while it is
    /// open; recording a gesture, or playing a note, must not depend on
    /// where the user's face points.
    private var borrowed = false
    /// Frames since the last face observation.
    private var sinceObservation = 0

    /// Called on the camera queue for every frame the idle throttle passed.
    /// `observe` runs Vision outside the lock (only this queue calls
    /// `assess`, so the gate cannot be fed concurrently) and only on the
    /// strided frames that are due. Returns the verdict plus whether it
    /// changed, so the controller hops to the main actor on transitions only.
    func assess(at time: TimeInterval,
                observe: () -> AttentionGate.Observation?) -> (attentive: Bool, changed: Bool) {
        lock.lock()
        guard gate.config.enabled, !borrowed else {
            sinceObservation = 0
            lock.unlock()
            return (true, false)
        }
        sinceObservation += 1
        let due = sinceObservation >= Self.observationStride
        if due { sinceObservation = 0 }
        let held = gate.attentive
        lock.unlock()

        guard due, let observation = observe() else { return (held, false) }

        lock.lock()
        defer { lock.unlock() }
        let verdict = gate.assess(observation, interacting: interacting, at: time)
        return (verdict, verdict != held)
    }

    /// The verdict as of the last assessment — for callers off the frame
    /// path (settings changes reconciling published UI state).
    var attentive: Bool {
        lock.withLock { gate.attentive }
    }

    func setConfig(_ config: AttentionGate.Config) {
        lock.withLock { gate.setConfig(config) }
    }

    func setInteracting(_ value: Bool) {
        lock.withLock { interacting = value }
    }

    func setCameraBorrowed(_ value: Bool) {
        lock.withLock { borrowed = value }
    }

    /// A fresh tracking session (start, resume from the lock screen) begins
    /// attentive with no history, exactly like the engine and the throttle.
    func reset() {
        lock.withLock {
            gate.reset()
            sinceObservation = 0
        }
    }
}
