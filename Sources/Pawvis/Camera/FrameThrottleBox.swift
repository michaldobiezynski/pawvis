import Foundation
import PawvisCore

/// The camera-queue face of the pure `IdleThrottle` and `CameraStallClock`
/// policies: the state machines under one lock, with the main-actor facts
/// they need (a press or scroll in flight, a window borrowing the camera, Low Power Mode)
/// mirrored in so the tap can consult them off-main without touching the
/// main actor.
///
/// The tap calls `shouldRunInference` for every captured frame and
/// `sawHands` after Vision on the frames that ran; `PawvisController`
/// pushes the exemption and power inputs whenever they change. Frames
/// answered `false` are dropped before inference and never reach the
/// gesture engine.
///
/// The stall clock lives here — not on the main actor — because its
/// evidence must be every *captured* frame, and only the tap sees those:
/// `shouldRunInference` stamps it before deciding, so a frame the throttle
/// skips still proves the camera is delivering. (Stamping downstream in
/// `processFrame` once let the idle throttle starve the watchdog into
/// convicting a live camera.) The watchdog reads the verdict on the main
/// actor via `cameraStalled`.
final class FrameThrottleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var throttle = IdleThrottle()
    private var stall = CameraStallClock()
    /// A button held or a scroll active: never throttle. Hands are obviously
    /// present then, but the guard is explicit, not inferred.
    private var interacting = false
    /// A window (the trainer, the theremin) owns the stream while it is
    /// open, and it wants every frame — a 5 fps preview would record 5 fps
    /// templates, and a 5 fps theremin would stutter.
    private var borrowed = false
    private var lowPower = false
    /// Captured frames since launch, stamped at the tap alongside the stall
    /// clock. The watchdog uses it as *positive* evidence that a camera is
    /// delivering: "not stalled" is also true inside a warm-up grace, when
    /// nothing has arrived yet, so clearing a failure on that alone would
    /// flap. A count that has advanced cannot be anything but new frames.
    private var frameCount: UInt64 = 0

    /// Called on the camera queue for every captured frame. Stamps the stall
    /// clock first — a frame this verdict skips still proves the camera is
    /// alive — then answers whether the frame runs Vision.
    func shouldRunInference(at time: TimeInterval) -> Bool {
        lock.withLock {
            stall.noteFrame(at: time)
            frameCount &+= 1
            return throttle.shouldRunInference(at: time,
                                               exempt: interacting || borrowed,
                                               lowPower: lowPower)
        }
    }

    /// Captured frames so far, read on the main actor by the watchdog.
    var capturedFrames: UInt64 {
        lock.withLock { frameCount }
    }

    /// Restart the no-frames countdown with a warm-up grace. Called on the
    /// main actor by every path that starts, restarts, or hands back the
    /// camera — synchronously, at the moment the pause flag flips, never
    /// only from the asynchronous running-state callback.
    func armStallClock(at time: TimeInterval, grace: TimeInterval) {
        lock.withLock { stall.arm(at: time, grace: grace) }
    }

    /// The watchdog's verdict: no captured frames for too long, past grace.
    func cameraStalled(at time: TimeInterval) -> Bool {
        lock.withLock { stall.isStalled(at: time) }
    }

    /// Called on the camera queue after Vision ran on a processed frame.
    func sawHands(_ seen: Bool, at time: TimeInterval) {
        lock.withLock { throttle.sawHands(seen, at: time) }
    }

    func setInteracting(_ value: Bool) {
        lock.withLock { interacting = value }
    }

    func setCameraBorrowed(_ value: Bool) {
        lock.withLock { borrowed = value }
    }

    func setLowPower(_ value: Bool) {
        lock.withLock { lowPower = value }
    }

    /// A fresh tracking session (start, or resume from the lock screen)
    /// begins at full rate.
    func reset() {
        lock.withLock { throttle.reset() }
    }
}
