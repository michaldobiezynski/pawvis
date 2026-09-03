import XCTest
@testable import PawvisCore

/// Joystick cursor mode: the hand is a stick, not a pointer. The centre is
/// captured when control arms and the hand's offset from it steers the
/// cursor, so the hand never has to travel — or leave the camera's view.
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

    func testArmingStartsAtTheScreenCentreAndCapturesTheHandAsCentre() {
        let (events, overlay) = feed([home], at: 0)
        XCTAssertEqual(moves(events), [Vec2(0.5, 0.5)], "the very first arm has nowhere better to start")
        XCTAssertEqual(overlay.cursor, Vec2(0.5, 0.5))
        XCTAssertEqual(overlay.joystick, JoystickOverlay(offset: .zero, deflection: 0),
                       "the pad sees a centred stick")
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

    func testAHandInsideTheDeadZoneNeverMovesTheCursor() {
        feed([home], at: 0)
        let still = feedFrames([home], from: 1.0 / 30, count: 60)
        XCTAssertTrue(moves(still.events).isEmpty, "a still hand steers nothing, however long it stays")
        let nudged = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.53, 0.7), scale: 0.15)],
                                from: 61.0 / 30, count: 30)
        XCTAssertTrue(moves(nudged.events).isEmpty, "0.03 of travel is inside the 0.04 dead zone")
    }

    // MARK: - Steering

    func testAnOffsetSteersTheCursorContinuously() {
        feed([home], at: 0)
        let steered = feedFrames([right], from: 1.0 / 30, count: 30)
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
        feed([home], at: 0)
        let far = SyntheticHand.openRelaxed(wrist: Vec2(0.9, 0.7), scale: 0.15)
        let steered = feedFrames([far], from: 1.0 / 30, count: 40)
        let positions = moves(steered.events)
        let steps = zip(positions, positions.dropFirst()).map { $1.x - $0.x }
        let perFrame = GestureConfig.default.joystickMaxSpeed / 30
        for step in steps.prefix(5) {
            XCTAssertEqual(step, perFrame, accuracy: 1e-6, "top speed, one frame's worth per frame")
        }
        XCTAssertEqual(steered.overlay.cursor, Vec2(1, 0.5), "the cursor stops at the screen edge")
    }

    // MARK: - Parking, losing the hand

    func testAFistParksTheCursorAndReopeningElsewhereRecentres() {
        var config = Self.joystickConfig()
        config.controlTrigger = .openHand
        engine = GestureEngine(config: config)

        let armed = feedFrames([home], from: 0, count: 4)
        XCTAssertTrue(armed.overlay.armed)
        XCTAssertEqual(moves(armed.events), [Vec2(0.5, 0.5)])
        let steered = feedFrames([right], from: 4.0 / 30, count: 15)
        let parkedAt = steered.overlay.cursor
        XCTAssertGreaterThan(parkedAt?.x ?? 0, 0.5)

        let fist = SyntheticHand.fist(wrist: Vec2(0.6, 0.7), scale: 0.15)
        let closing = feedFrames([fist], from: 19.0 / 30, count: 12)
        XCTAssertFalse(closing.overlay.armed)
        let held = feedFrames([fist], from: 31.0 / 30, count: 5)
        XCTAssertTrue(moves(held.events).isEmpty)
        XCTAssertEqual(held.overlay.cursor, closing.overlay.cursor, "parked: the cursor stays exactly put")
        XCTAssertEqual(held.overlay.joystick, JoystickOverlay(), "…and the pad shows a centred stick")

        let reopened = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.5), scale: 0.15)],
                                  from: 36.0 / 30, count: 10)
        XCTAssertTrue(reopened.overlay.armed)
        XCTAssertTrue(moves(reopened.events).isEmpty, "the new hand position is the new centre, not a push")
        XCTAssertEqual(reopened.overlay.cursor, closing.overlay.cursor)

        let pushed = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.5), scale: 0.15)],
                                from: 46.0 / 30, count: 5)
        let first = try? XCTUnwrap(moves(pushed.events).first)
        XCTAssertGreaterThan(first?.x ?? 0, closing.overlay.cursor?.x ?? 1,
                             "steering resumes from the parked spot, in the pushed direction")
    }

    func testLosingTheHandForgetsTheCentreWithoutMovingTheCursor() {
        feed([home], at: 0)
        let steered = feedFrames([right], from: 1.0 / 30, count: 30)
        feed([], at: 10) // far past the tracking-loss grace
        let returned = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.2, 0.4), scale: 0.15)],
                                  from: 11, count: 30)
        XCTAssertTrue(moves(returned.events).isEmpty, "a returning hand is a new centre, wherever it is")
        XCTAssertEqual(returned.overlay.cursor, steered.overlay.cursor)
    }

    func testALateFrameIntegratesNothing() {
        feed([home], at: 0)
        let before = feedFrames([right], from: 1.0 / 30, count: 5)
        // One frame arriving 0.28 s after the last (inside the tracking-loss
        // grace, so nothing was released) must not leap the cursor by 0.28 s
        // of travel.
        let late = feed([right], at: 6.0 / 30 + 0.25)
        XCTAssertTrue(moves(late.events).isEmpty)
        XCTAssertEqual(late.overlay.cursor, before.overlay.cursor)
    }

    // MARK: - Living with the other gestures

    func testAHeldPressDragsAlongTheSteeredPath() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.5, 0.7))], from: 0, count: 5)
        let pressed = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.5, 0.7))],
                                 from: 5.0 / 30, count: 4)
        XCTAssertEqual(downs(pressed.events), 1)
        let dragged = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.7, 0.7))],
                                 from: 9.0 / 30, count: 20)
        let xs = drags(dragged.events).map(\.x)
        XCTAssertGreaterThanOrEqual(xs.count, 12)
        XCTAssertTrue(isAscending(xs))
        XCTAssertTrue(dragged.overlay.isDragging)
        let released = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.7, 0.7))],
                                  from: 29.0 / 30, count: 4)
        XCTAssertEqual(ups(released.events), 1)
    }

    func testAnActiveScrollHoldsTheStick() {
        feedFrames([home], from: 0, count: 5)
        feedFrames([right], from: 5.0 / 30, count: 10)
        let scrollHand = SyntheticHand.scrollPose(wrist: Vec2(0.7, 0.7), scale: 0.15)
        let engaged = feedFrames([scrollHand], from: 15.0 / 30, count: 6)
        XCTAssertTrue(engaged.overlay.isScrolling)
        let scrolling = feedFrames([scrollHand], from: 21.0 / 30, count: 30)
        XCTAssertTrue(moves(scrolling.events).isEmpty, "the stick is parked while the wheel turns")
        XCTAssertEqual(scrolling.overlay.cursor, engaged.overlay.cursor)

        let resumed = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.7, 0.7), scale: 0.15)],
                                 from: 51.0 / 30, count: 8)
        let first = try? XCTUnwrap(moves(resumed.events).first)
        let parked = try? XCTUnwrap(scrolling.overlay.cursor)
        XCTAssertLessThanOrEqual(first?.distance(to: parked ?? .zero) ?? 1,
                                 GestureConfig.default.joystickMaxSpeed / 30 + 1e-9,
                                 "unparking resumes from where the scroll left the cursor, no leap")
    }

    func testAutoReachFreezesWhileSteeringAndDriftsOnceParked() {
        var config = Self.joystickConfig()
        config.controlTrigger = .openHand
        config.reachMode = .auto
        engine = GestureEngine(config: config)
        let big = SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.8), scale: 0.28)

        let armed = feedFrames([big], from: 0, count: 3)
        XCTAssertTrue(armed.overlay.armed)
        let boxAtArm = engine.effectiveInteractionBox
        XCTAssertGreaterThan(boxAtArm.yMin, 0, "the box had started fitting the hand before control armed")

        feedFrames([big], from: 3.0 / 30, count: 30)
        XCTAssertEqual(engine.effectiveInteractionBox, boxAtArm,
                       "the stick measures its offset in the box's space: the box must not move under it")

        let parked = feedFrames([SyntheticHand.fist(wrist: Vec2(0.5, 0.8), scale: 0.28)], from: 33.0 / 30, count: 14)
        XCTAssertFalse(parked.overlay.armed)
        XCTAssertNotEqual(engine.effectiveInteractionBox, boxAtArm, "parked, the fit resumes")
    }
}
