import XCTest
@testable import PawvisCore

/// Joystick cursor mode: the hand is a stick, not a pointer. Once the armed
/// hand has settled its position is the centre, and the hand's offset from
/// it steers the cursor, so the hand never has to travel, or leave the
/// camera's view.
final class JoystickTests: XCTestCase {
    var engine: GestureEngine!

    /// Identity mapping, no smoothing, `.anyHand`: the same footing as the
    /// engine suite, with the joystick switched on.
    private static func joystickConfig() -> GestureConfig {
        var config = GestureConfig.default
        config.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
        config.reachMode = .manual
        config.mirrorCamera = false
        config.smoothing = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
        config.controlTrigger = .anyHand
        config.cursorMode = .joystick
        return config
    }

    private let home = SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7), scale: 0.15)
    private let right = SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.7), scale: 0.15)
    private let topSpeedPerFrame = GestureConfig.default.joystickMaxSpeed / 30

    override func setUp() {
        super.setUp()
        engine = GestureEngine(config: Self.joystickConfig())
    }

    @discardableResult
    private func feed(_ hands: [Hand], at t: TimeInterval) -> (events: [GestureEvent], overlay: OverlayState) {
        engine.process(HandFrame(time: t, hands: hands))
    }

    /// Identical frames at 30 fps from `from`; the events of all of them and
    /// the overlay of the last.
    @discardableResult
    private func feedFrames(_ hands: [Hand], from: TimeInterval, count: Int)
        -> (events: [GestureEvent], overlay: OverlayState) {
        var events: [GestureEvent] = []
        var overlay = OverlayState()
        for i in 0..<count {
            let result = feed(hands, at: from + Double(i) / 30)
            events += result.events
            overlay = result.overlay
        }
        return (events, overlay)
    }

    /// Enough still frames for the centre to be captured (arming in
    /// `.openHand` takes 3, settling another 3).
    @discardableResult
    private func settle(_ hands: [Hand], from: TimeInterval = 0) -> (events: [GestureEvent], overlay: OverlayState) {
        feedFrames(hands, from: from, count: 8)
    }

    private func moves(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .move(let to) = $0 { return to }
            return nil
        }
    }

    private func drags(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .drag(.left, let to) = $0 { return to }
            return nil
        }
    }

    private func downs(_ events: [GestureEvent]) -> Int {
        events.filter {
            if case .buttonDown(.left, _, _) = $0 { return true }
            return false
        }.count
    }

    private func ups(_ events: [GestureEvent]) -> Int {
        events.filter {
            if case .buttonUp(.left, _, _) = $0 { return true }
            return false
        }.count
    }

    private func isAscending(_ values: [Double]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }

    // MARK: - Config

    func testDefaultModeIsAbsolute() {
        XCTAssertEqual(GestureConfig.default.cursorMode, .absolute)
    }

    func testDecodingClampsTheJoystickTuningAndIgnoresAnUnknownMode() throws {
        let json = #"{"cursorMode":"warp","joystickDeadZone":9,"joystickThrow":-1,"joystickMaxSpeed":100,"joystickCurve":0}"#
        let decoded = try JSONDecoder().decode(GestureConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.cursorMode, .absolute, "an unknown mode keeps the default")
        XCTAssertEqual(decoded.joystickDeadZone, GestureConfig.joystickDeadZoneRange.upperBound)
        XCTAssertEqual(decoded.joystickThrow, GestureConfig.joystickThrowRange.lowerBound)
        XCTAssertEqual(decoded.joystickMaxSpeed, GestureConfig.joystickMaxSpeedRange.upperBound)
        XCTAssertEqual(decoded.joystickCurve, GestureConfig.joystickCurveRange.lowerBound)
    }

    func testJoystickSettingsRoundTrip() throws {
        var config = GestureConfig.default
        config.cursorMode = .joystick
        config.joystickThrow = 0.3
        config.joystickMaxSpeed = 2
        let decoded = try JSONDecoder().decode(GestureConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    // MARK: - The velocity law

    func testVelocityIsZeroInsideTheDeadZone() {
        let config = GestureConfig.default
        let result = GestureEngine.joystickVelocity(offset: Vec2(config.joystickDeadZone * 0.9, 0), config: config)
        XCTAssertEqual(result.velocity, .zero)
        XCTAssertEqual(result.deflection, 0)
    }

    func testVelocityFollowsTheCurveUpToTheThrow() {
        let config = GestureConfig.default // dead zone 0.04, throw 0.25, curve 2, top 1.2
        let midway = GestureEngine.joystickVelocity(offset: Vec2(0.145, 0), config: config)
        XCTAssertEqual(midway.velocity.x, config.joystickMaxSpeed * 0.25, accuracy: 1e-9,
                       "halfway along the travel, a quadratic curve gives a quarter of top speed")
        XCTAssertEqual(midway.velocity.y, 0, accuracy: 1e-12)
        let full = GestureEngine.joystickVelocity(offset: Vec2(0, config.joystickThrow), config: config)
        XCTAssertEqual(full.velocity.y, config.joystickMaxSpeed, accuracy: 1e-9)
        XCTAssertEqual(full.deflection, 1)
        let past = GestureEngine.joystickVelocity(offset: Vec2(0, 0.9), config: config)
        XCTAssertEqual(past.velocity.y, config.joystickMaxSpeed, accuracy: 1e-9,
                       "pushing past the throw changes nothing: the stick is at its stop")
    }

    // MARK: - Arming and the centre

    func testArmingStartsAtTheScreenCentreAndCapturesTheHandOnceSettled() {
        let (events, overlay) = feed([home], at: 0)
        XCTAssertEqual(moves(events), [Vec2(0.5, 0.5)], "the very first arm has nowhere better to start")
        XCTAssertEqual(overlay.cursor, Vec2(0.5, 0.5))
        XCTAssertEqual(overlay.joystick, JoystickOverlay(), "the pad sees a centred stick")
        let settling = feedFrames([home], from: 1.0 / 30, count: 7)
        XCTAssertTrue(moves(settling.events).isEmpty)
        let pushed = feedFrames([right], from: 8.0 / 30, count: 5)
        XCTAssertFalse(moves(pushed.events).isEmpty, "…and once settled, a push steers")
    }

    func testAHandStillMovingIntoPositionIsNotACentre() {
        // The open hand arrives over ten frames, sliding right the whole
        // way: a centre taken mid-slide would be a push the user never made.
        var events: [GestureEvent] = []
        for i in 0..<10 {
            let hand = SyntheticHand.openRelaxed(wrist: Vec2(0.3 + 0.02 * Double(i), 0.7), scale: 0.15)
            events += feed([hand], at: Double(i) / 30).events
        }
        XCTAssertEqual(moves(events).count, 1, "only the first frame's cursor seat; no steering while it slides")
        let rested = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.48, 0.7), scale: 0.15)], from: 10.0 / 30, count: 6)
        XCTAssertTrue(moves(rested.events).isEmpty, "where it came to rest is the centre")
        let pushed = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.58, 0.7), scale: 0.15)], from: 16.0 / 30, count: 5)
        XCTAssertTrue(isAscending(moves(pushed.events).map(\.x)))
        XCTAssertGreaterThanOrEqual(moves(pushed.events).count, 4)
    }

    func testAbsoluteModeCarriesNoStick() {
        var config = Self.joystickConfig()
        config.cursorMode = .absolute
        engine = GestureEngine(config: config)
        let (events, overlay) = feed([home], at: 0)
        XCTAssertNil(overlay.joystick)
        XCTAssertEqual(moves(events).first, overlay.cursor, "direct mode is untouched: the cursor is the hand")
        XCTAssertNotEqual(overlay.cursor, Vec2(0.5, 0.5))
    }

    func testANoHandsFrameStillCarriesTheStick() {
        XCTAssertEqual(feed([], at: 0).overlay.joystick, JoystickOverlay(), "the pad must not flicker off between hands")
        var config = Self.joystickConfig()
        config.cursorMode = .absolute
        engine = GestureEngine(config: config)
        XCTAssertNil(feed([], at: 0).overlay.joystick)
    }

    func testAHandInsideTheDeadZoneNeverMovesTheCursor() {
        settle([home])
        let still = feedFrames([home], from: 8.0 / 30, count: 60)
        XCTAssertTrue(moves(still.events).isEmpty, "a still hand steers nothing, however long it stays")
        let nudged = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.53, 0.7), scale: 0.15)],
                                from: 68.0 / 30, count: 30)
        XCTAssertTrue(moves(nudged.events).isEmpty, "0.03 of travel is inside the 0.04 dead zone")
    }

    func testRestingInsideTheDeadZoneBecomesTheCentre() {
        settle([home])
        feedFrames([right], from: 8.0 / 30, count: 15)
        // Back to just inside the dead zone and rest there: the centre
        // follows within half a second.
        let rest = SyntheticHand.openRelaxed(wrist: Vec2(0.53, 0.7), scale: 0.15)
        let resting = feedFrames([rest], from: 23.0 / 30, count: 40)
        XCTAssertTrue(moves(resting.events).isEmpty)
        // 0.065 from the original centre would steer; 0.035 from the rest
        // position does not.
        let nudged = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.565, 0.7), scale: 0.15)],
                                from: 63.0 / 30, count: 10)
        XCTAssertTrue(moves(nudged.events).isEmpty, "the rest position is the centre now")
    }

    // MARK: - Steering

    func testAnOffsetSteersTheCursorContinuously() {
        settle([home])
        let steered = feedFrames([right], from: 8.0 / 30, count: 30)
        let xs = moves(steered.events).map(\.x)
        XCTAssertGreaterThanOrEqual(xs.count, 25, "every frame moves the cursor a little")
        XCTAssertTrue(isAscending(xs), "…always in the stick's direction")
        XCTAssertTrue(moves(steered.events).allSatisfy { $0.y == 0.5 }, "a purely sideways push never drifts vertically")
        let stick = try? XCTUnwrap(steered.overlay.joystick)
        XCTAssertEqual(stick?.offset.x ?? 0, 0.1, accuracy: 1e-6)
        XCTAssertGreaterThan(stick?.deflection ?? 0, 0)
        XCTAssertLessThan(stick?.deflection ?? 1, 1)
    }

    func testFullThrowRunsAtTopSpeedAndStopsAtTheEdge() {
        settle([home])
        let far = SyntheticHand.openRelaxed(wrist: Vec2(0.9, 0.7), scale: 0.15)
        let steered = feedFrames([far], from: 8.0 / 30, count: 40)
        let positions = moves(steered.events)
        let steps = zip(positions, positions.dropFirst()).map { $1.x - $0.x }
        for step in steps.prefix(5) {
            XCTAssertEqual(step, topSpeedPerFrame, accuracy: 1e-6, "top speed, one frame's worth per frame")
        }
        XCTAssertEqual(steered.overlay.cursor, Vec2(1, 0.5), "the cursor stops at the screen edge")
    }

    func testAPointedHandStillSteers() {
        // Pushing the hand down or forward tips the fingers toward the camera
        // and reads as the pointed pose; the stick must not stall on it.
        settle([SyntheticHand.pointedHand(struck: false, wrist: Vec2(0.5, 0.7))])
        let pushed = feedFrames([SyntheticHand.pointedHand(struck: false, wrist: Vec2(0.62, 0.7))],
                                from: 8.0 / 30, count: 15)
        XCTAssertGreaterThanOrEqual(moves(pushed.events).count, 10)
        XCTAssertTrue(isAscending(moves(pushed.events).map(\.x)))
    }

    // MARK: - Parking, losing the hand, handing over

    func testAFistParksTheCursorAndReopeningElsewhereRecentres() {
        var config = Self.joystickConfig()
        config.controlTrigger = .openHand
        engine = GestureEngine(config: config)

        let armed = settle([home])
        XCTAssertTrue(armed.overlay.armed)
        XCTAssertEqual(moves(armed.events), [Vec2(0.5, 0.5)])
        let steered = feedFrames([right], from: 8.0 / 30, count: 15)
        XCTAssertGreaterThan(steered.overlay.cursor?.x ?? 0, 0.5)

        let fist = SyntheticHand.fist(wrist: Vec2(0.6, 0.7), scale: 0.15)
        let closing = feedFrames([fist], from: 23.0 / 30, count: 12)
        XCTAssertFalse(closing.overlay.armed)
        let held = feedFrames([fist], from: 35.0 / 30, count: 5)
        XCTAssertTrue(moves(held.events).isEmpty)
        XCTAssertEqual(held.overlay.cursor, closing.overlay.cursor, "parked: the cursor stays exactly put")
        XCTAssertEqual(held.overlay.joystick, JoystickOverlay(), "…and the pad shows a centred stick")

        let reopened = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.5), scale: 0.15)],
                                  from: 40.0 / 30, count: 10)
        XCTAssertTrue(reopened.overlay.armed)
        XCTAssertTrue(moves(reopened.events).isEmpty, "the new hand position is the new centre, not a push")
        XCTAssertEqual(reopened.overlay.cursor, closing.overlay.cursor)

        let pushed = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.5), scale: 0.15)],
                                from: 50.0 / 30, count: 5)
        let first = try? XCTUnwrap(moves(pushed.events).first)
        XCTAssertGreaterThan(first?.x ?? 0, closing.overlay.cursor?.x ?? 1,
                             "steering resumes from the parked spot, in the pushed direction")
    }

    func testLosingTheHandForgetsTheCentreWithoutMovingTheCursor() {
        settle([home])
        let steered = feedFrames([right], from: 8.0 / 30, count: 30)
        feed([], at: 10) // far past the tracking-loss grace
        let returned = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.2, 0.4), scale: 0.15)],
                                  from: 11, count: 30)
        XCTAssertTrue(moves(returned.events).isEmpty, "a returning hand is a new centre, wherever it is")
        XCTAssertEqual(returned.overlay.cursor, steered.overlay.cursor)
    }

    func testALateFrameIntegratesNothing() {
        settle([home])
        let before = feedFrames([right], from: 8.0 / 30, count: 5)
        // One frame arriving 0.28 s after the last (inside the tracking-loss
        // grace, so nothing was released) must not leap the cursor by 0.28 s
        // of travel.
        let late = feed([right], at: 13.0 / 30 + 0.25)
        XCTAssertTrue(moves(late.events).isEmpty)
        XCTAssertEqual(late.overlay.cursor, before.overlay.cursor)
    }

    func testABystanderNeverInheritsTheCentre() {
        var config = Self.joystickConfig()
        config.controlTrigger = .openHand
        engine = GestureEngine(config: config)
        let bystander = SyntheticHand.openRelaxed(wrist: Vec2(0.15, 0.4), scale: 0.15, chirality: .left)

        settle([home])
        let both = feedFrames([home, bystander], from: 8.0 / 30, count: 5)
        XCTAssertTrue(moves(both.events).isEmpty)
        let parked = both.overlay.cursor

        // The steering hand leaves; the open bystander inherits control past
        // the grace, and must start from its own rest position, not from an
        // offset to a centre it never settled.
        let inherited = feedFrames([bystander], from: 13.0 / 30, count: 45)
        XCTAssertTrue(inherited.overlay.armed, "setup check: the open bystander took control")
        XCTAssertTrue(moves(inherited.events).isEmpty, "a still hand never steers, whichever hand it is")
        XCTAssertEqual(inherited.overlay.cursor, parked)
    }

    func testAOneFrameDropoutBesideAnotherHandNeverSteers() {
        // `.anyHand`: a single missed Vision frame of the steering hand hands
        // the slot to the bystander at once.
        let bystander = SyntheticHand.openRelaxed(wrist: Vec2(0.15, 0.4), scale: 0.15, chirality: .left)
        settle([home])
        let both = feedFrames([home, bystander], from: 8.0 / 30, count: 5)
        let parked = both.overlay.cursor
        let dropped = feed([bystander], at: 13.0 / 30)
        let back = feedFrames([home, bystander], from: 14.0 / 30, count: 20)
        XCTAssertTrue(moves(dropped.events + back.events).isEmpty)
        XCTAssertEqual(back.overlay.cursor, parked)
    }

    // MARK: - Living with the other gestures

    func testAHeldPressDragsAlongTheSteeredPath() {
        settle([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.5, 0.7))])
        let pressed = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.5, 0.7))],
                                 from: 8.0 / 30, count: 4)
        XCTAssertEqual(downs(pressed.events), 1)
        let dragged = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.7, 0.7))],
                                 from: 12.0 / 30, count: 20)
        let xs = drags(dragged.events).map(\.x)
        XCTAssertGreaterThanOrEqual(xs.count, 12)
        XCTAssertTrue(isAscending(xs))
        XCTAssertTrue(dragged.overlay.isDragging)
        let released = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.7, 0.7))],
                                  from: 32.0 / 30, count: 4)
        XCTAssertEqual(ups(released.events), 1)
    }

    func testAScrollsHandTravelIsNotAPush() {
        settle([home])
        let engaged = feedFrames([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7), scale: 0.15)], from: 8.0 / 30, count: 6)
        XCTAssertTrue(engaged.overlay.isScrolling, "setup check")
        XCTAssertTrue(moves(engaged.events).isEmpty)
        // Scrolling is palm travel: the hand ends up somewhere else.
        let travelled = feedFrames([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.5), scale: 0.15)], from: 14.0 / 30, count: 10)
        XCTAssertTrue(moves(travelled.events).isEmpty, "the stick is parked while the wheel turns")
        let parked = travelled.overlay.cursor
        // The pose opens where the scroll left the hand, and the hand rests
        // there: that is the centre now, so nothing moves.
        let released = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.5), scale: 0.15)], from: 24.0 / 30, count: 30)
        XCTAssertFalse(released.overlay.isScrolling)
        XCTAssertTrue(moves(released.events).isEmpty, "where the scroll left the hand is not a push")
        XCTAssertEqual(released.overlay.cursor, parked)
        // A real push from there resumes from where the scroll left the cursor.
        let pushed = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.5), scale: 0.15)], from: 54.0 / 30, count: 5)
        let first = try? XCTUnwrap(moves(pushed.events).first)
        XCTAssertLessThanOrEqual(first?.distance(to: parked ?? .zero) ?? 1, topSpeedPerFrame + 1e-9)
    }

    func testAutoReachFreezesWhilePushingAndFitsAtRest() {
        var config = Self.joystickConfig()
        config.controlTrigger = .openHand
        config.reachMode = .auto
        engine = GestureEngine(config: config)
        let big = SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.8), scale: 0.28)
        let bigPush = SyntheticHand.openRelaxed(wrist: Vec2(0.62, 0.8), scale: 0.28)

        let rested = settle([big])
        XCTAssertTrue(rested.overlay.armed)
        let boxAtRest = engine.effectiveInteractionBox
        XCTAssertGreaterThan(boxAtRest.yMin, 0, "the box fits the hand while it rests")

        feedFrames([bigPush], from: 8.0 / 30, count: 20)
        XCTAssertEqual(engine.effectiveInteractionBox, boxAtRest,
                       "the stick measures its offset in the box's space: the box must not move under a push")

        feedFrames([big], from: 28.0 / 30, count: 20)
        XCTAssertNotEqual(engine.effectiveInteractionBox, boxAtRest, "at rest, the fit resumes")
    }

    func testAutoReachStillFitsInAnyHandMode() {
        var config = Self.joystickConfig()
        config.reachMode = .auto
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.8), scale: 0.28)], from: 0, count: 40)
        XCTAssertGreaterThan(engine.effectiveInteractionBox.yMin, 0.3,
                             "a resting stick never blocks the fit, even with no disarm to free it")
    }

    func testSwitchingModesClearsTheCentreWithoutMovingTheCursor() {
        settle([home])
        feedFrames([right], from: 8.0 / 30, count: 10)
        engine.config.cursorMode = .absolute
        let direct = feed([right], at: 18.0 / 30)
        XCTAssertNil(direct.overlay.joystick)
        engine.config.cursorMode = .joystick
        let back = feedFrames([right], from: 19.0 / 30, count: 10)
        XCTAssertTrue(moves(back.events).isEmpty, "the hand's position on return is the new centre, not a push")
        XCTAssertEqual(back.overlay.cursor, direct.overlay.cursor)
    }

    func testResetKeepsTheSteeredPositionAndASeedOverridesIt() {
        settle([home])
        let steered = feedFrames([right], from: 8.0 / 30, count: 10)
        let before = try? XCTUnwrap(steered.overlay.cursor)

        engine.reset()
        let resumed = feedFrames([home], from: 1, count: 6)
        XCTAssertEqual(moves(resumed.events).count, 1, "one re-seat of the cursor, then stillness")
        XCTAssertEqual(moves(resumed.events).first?.distance(to: before ?? .zero) ?? 1, 0, accuracy: 0.003,
                       "…exactly where it was: a reset never warps the cursor to the middle")

        engine.reset()
        engine.seedJoystick(at: Vec2(0.2, 0.2))
        let seeded = feedFrames([home], from: 2, count: 6)
        XCTAssertEqual(moves(seeded.events), [Vec2(0.2, 0.2)], "the app's seed is where the real pointer is")
    }
}
