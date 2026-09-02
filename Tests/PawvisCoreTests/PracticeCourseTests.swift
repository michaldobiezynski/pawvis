import XCTest
@testable import PawvisCore

/// The practice round's pure rules: which lessons a configuration gets,
/// when the round opens on its own, and the small verdict machines the
/// lessons run on (dwell, drop, the two-leg scroll, the status line).
final class PracticeCourseTests: XCTestCase {
    // MARK: Course composition

    func testDefaultsPracticeEveryBasicMotion() {
        XCTAssertEqual(
            PracticeCourse.lessons(for: .default),
            [.takeControl, .move, .click, .drag, .scroll, .rightClick])
    }

    func testAnyHandTriggerDropsTheTakeControlLesson() {
        var config = GestureConfig.default
        config.controlTrigger = .anyHand
        XCTAssertEqual(PracticeCourse.lessons(for: config).first, .move)
        XCTAssertFalse(PracticeCourse.lessons(for: config).contains(.takeControl))
    }

    func testSwitchedOffGesturesLeaveTheCourse() {
        var config = GestureConfig.default
        config.scrollEnabled = false
        config.rightClickEnabled = false
        XCTAssertEqual(PracticeCourse.lessons(for: config), [.takeControl, .move, .click, .drag])
    }

    /// Gestures-only mode never touches the mouse, so there is nothing the
    /// round could teach: it is empty, and the policy below keeps it shut.
    func testGesturesOnlyModeHasNothingToPractice() {
        var config = GestureConfig.default
        config.controlTrigger = .gesturesOnly
        XCTAssertEqual(PracticeCourse.lessons(for: config), [])
    }

    func testCourseOrderNeverChanges() {
        let lessons = PracticeCourse.lessons(for: .default)
        let ranks = lessons.map { PracticeLesson.allCases.firstIndex(of: $0)! }
        XCTAssertEqual(ranks, ranks.sorted())
    }

    // MARK: Auto-open policy

    func testOpensOnceAfterTheWelcomeTour() {
        let lessons = PracticeCourse.lessons(for: .default)
        XCTAssertTrue(PracticePolicy.opensAfterWelcome(seen: false, lessons: lessons))
        XCTAssertFalse(PracticePolicy.opensAfterWelcome(seen: true, lessons: lessons))
    }

    func testNeverOpensWithNothingToPractice() {
        XCTAssertFalse(PracticePolicy.opensAfterWelcome(seen: false, lessons: []))
    }

    // MARK: Dwell

    func testDwellFillsWhileInsideAndCompletesOnce() {
        var dwell = PracticeDwell(seconds: 0.4)
        XCTAssertFalse(dwell.update(inside: true, at: 10.0))
        XCTAssertEqual(dwell.progress, 0, accuracy: 1e-9)
        XCTAssertFalse(dwell.update(inside: true, at: 10.2))
        XCTAssertEqual(dwell.progress, 0.5, accuracy: 1e-9)
        XCTAssertTrue(dwell.update(inside: true, at: 10.4))
        XCTAssertEqual(dwell.progress, 1, accuracy: 1e-9)
    }

    /// A pointer that merely crosses the target must not pop it: leaving
    /// empties the timer, and coming back starts it over.
    func testDwellEmptiesTheMomentThePointerLeaves() {
        var dwell = PracticeDwell(seconds: 0.4)
        _ = dwell.update(inside: true, at: 0)
        _ = dwell.update(inside: true, at: 0.3)
        XCTAssertFalse(dwell.update(inside: false, at: 0.35))
        XCTAssertEqual(dwell.progress, 0)
        XCTAssertFalse(dwell.update(inside: true, at: 0.4))
        XCTAssertFalse(dwell.update(inside: true, at: 0.7))
        XCTAssertTrue(dwell.update(inside: true, at: 0.8))
    }

    func testDwellResetForgetsTheEntry() {
        var dwell = PracticeDwell(seconds: 0.4)
        _ = dwell.update(inside: true, at: 0)
        dwell.reset()
        XCTAssertEqual(dwell.progress, 0)
        XCTAssertFalse(dwell.update(inside: true, at: 0.5))
    }

    // MARK: Targets

    /// Every target keeps its whole disc inside the arena, so nothing the
    /// round asks for can sit under the window's edge.
    func testEveryTargetStaysClearOfTheEdges() {
        let inset = PracticeTargets.edgeInset
        for lesson in [PracticeLesson.move, .click, .rightClick] {
            for round in 0..<lesson.rounds {
                let target = PracticeTargets.target(for: lesson, round: round)
                XCTAssert(target.x >= inset && target.x <= 1 - inset, "\(lesson) round \(round)")
                XCTAssert(target.y >= inset && target.y <= 1 - inset, "\(lesson) round \(round)")
            }
        }
        for round in 0..<PracticeLesson.drag.rounds {
            for point in [PracticeTargets.dragStart(round: round), PracticeTargets.dragSlot(round: round)] {
                XCTAssert(point.x >= inset && point.x <= 1 - inset)
                XCTAssert(point.y >= inset && point.y <= 1 - inset)
            }
        }
        XCTAssert(inset > PracticeTargets.targetRadius)
        XCTAssert(inset > PracticeDrag.dropTolerance)
    }

    func testConsecutiveTargetsAreApart() {
        for lesson in [PracticeLesson.move, .click, .rightClick] {
            for round in 1..<lesson.rounds {
                let a = PracticeTargets.target(for: lesson, round: round - 1)
                let b = PracticeTargets.target(for: lesson, round: round)
                XCTAssert(a.distance(to: b) > 3 * PracticeTargets.targetRadius, "\(lesson) round \(round)")
            }
        }
        for round in 0..<PracticeLesson.drag.rounds {
            let start = PracticeTargets.dragStart(round: round)
            let slot = PracticeTargets.dragSlot(round: round)
            XCTAssert(start.distance(to: slot) > 3 * PracticeDrag.dropTolerance)
        }
    }

    func testRoundsPastTheSweepWrapInsteadOfTrapping() {
        let first = PracticeTargets.target(for: .move, round: 0)
        XCTAssertEqual(PracticeTargets.target(for: .move, round: 3), first)
        XCTAssertEqual(PracticeTargets.target(for: .move, round: -3), first)
    }

    /// The disc test is round on screen, not in normalized space: on a
    /// wide arena a normalized x offset covers more points than the same
    /// y offset, so it must count for more.
    func testContainsIsRoundOnAWideArena() {
        let target = Vec2(0.5, 0.5)
        let radius = 0.1
        XCTAssertTrue(PracticeTargets.contains(Vec2(0.5, 0.59), target: target, radius: radius, aspect: 2))
        XCTAssertTrue(PracticeTargets.contains(Vec2(0.545, 0.5), target: target, radius: radius, aspect: 2))
        XCTAssertFalse(PracticeTargets.contains(Vec2(0.59, 0.5), target: target, radius: radius, aspect: 2))
        XCTAssertTrue(PracticeTargets.contains(Vec2(0.59, 0.5), target: target, radius: radius, aspect: 1))
    }

    // MARK: Drag

    func testDropCountsInsideTheToleranceOnly() {
        let slot = PracticeTargets.dragSlot(round: 0)
        XCTAssertTrue(PracticeDrag.dropped(token: slot + Vec2(0.05, 0.05), inSlot: slot))
        XCTAssertFalse(PracticeDrag.dropped(token: slot + Vec2(0.12, 0), inSlot: slot))
    }

    // MARK: Scroll

    func testScrollRuleWantsDownThenBackUp() {
        var rule = PracticeScrollRule(downTo: 500, upTo: 40)
        XCTAssertEqual(rule.phase, .down)
        XCTAssertFalse(rule.update(offset: 200))
        XCTAssertEqual(rule.phase, .down)
        // Reaching the top again before the treat changes nothing.
        XCTAssertFalse(rule.update(offset: 0))
        XCTAssertEqual(rule.phase, .down)
        XCTAssertFalse(rule.update(offset: 520))
        XCTAssertEqual(rule.phase, .up)
        XCTAssertFalse(rule.update(offset: 300))
        XCTAssertTrue(rule.update(offset: 30))
        XCTAssertEqual(rule.phase, .done)
        XCTAssertFalse(rule.update(offset: 0))
    }

    func testScrollProgressSpansBothLegs() {
        var rule = PracticeScrollRule(downTo: 400, upTo: 0)
        XCTAssertEqual(rule.progress(offset: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(rule.progress(offset: 200), 0.25, accuracy: 1e-9)
        _ = rule.update(offset: 400)
        XCTAssertEqual(rule.progress(offset: 400), 0.5, accuracy: 1e-9)
        XCTAssertEqual(rule.progress(offset: 100), 0.875, accuracy: 1e-9)
        _ = rule.update(offset: 0)
        XCTAssertEqual(rule.progress(offset: 0), 1, accuracy: 1e-9)
    }

    // MARK: Status line

    func testStatusLinePutsTheMostBlockingFactFirst() {
        var state = PracticeHandState()
        XCTAssertEqual(state.statusLine, "Tracking is off.")
        state.trackingOn = true
        state.blocked = "Paused on the lock screen"
        state.handsInView = 1
        XCTAssertEqual(state.statusLine, "Paused on the lock screen")
        state.blocked = nil
        state.handsInView = 0
        XCTAssert(state.statusLine.hasPrefix("No hand in view"))
        state.handsInView = 1
        state.armed = false
        XCTAssert(state.statusLine.hasPrefix("Hand found"))
        state.armed = true
        XCTAssert(state.statusLine.hasPrefix("You have the cursor"))
        state.closingProgress = 0.7
        XCTAssert(state.statusLine.hasPrefix("Dip forming"))
        state.grabbed = true
        XCTAssert(state.statusLine.contains("left button down"))
        state.isDragging = true
        XCTAssert(state.statusLine.hasPrefix("Dragging"))
        state.isScrolling = true
        XCTAssert(state.statusLine.hasPrefix("Scrolling"))
    }

    /// A press in flight outranks the arm state: the engine never lets go
    /// of a held button because the pose relaxed, and the line must not
    /// claim the hand lost control while the button is still down.
    func testPressInFlightOutranksTheArmState() {
        var state = PracticeHandState()
        state.trackingOn = true
        state.handsInView = 1
        state.armed = false
        state.rightGrabbed = true
        XCTAssert(state.statusLine.hasPrefix("Right button down"))
    }

    // MARK: Lesson metadata

    func testEveryLessonAsksForAtLeastOneRound() {
        for lesson in PracticeLesson.allCases {
            XCTAssertGreaterThanOrEqual(lesson.rounds, 1, "\(lesson)")
            XCTAssertFalse(lesson.title.isEmpty)
        }
    }
}
