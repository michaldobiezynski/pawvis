import AppKit
import Combine
import PawvisCore
import QuartzCore

// MARK: - The demo hand
//
// `PAWVIS_PRACTICE_DEMO=<state>` replaces the camera feed with a synthetic
// hand held in that state — an eyes-on hook in the spirit of
// `PAWVIS_OPEN_SETTINGS`, so a screenshot machine with no hand (or no
// camera) in front of it still shows the real coaching states: the mirror,
// the status line, the "Pawvis saw the dip" case. Only the *feedback* half
// is faked. The board still completes on real mouse events, because that is
// the whole design rule of the round (see `PracticeCourse`).

/// The hand state the synthetic feed pretends to be in.
enum PracticeDemoHand: String {
    case none, found, armed, grabbed, dragging, scrolling, right
}

// MARK: - Board state

/// Everything the arena draws, in one diffable value. One published struct
/// rather than a dozen properties: the 60 Hz tick assigns it once, and
/// SwiftUI re-renders only when something actually moved.
struct PracticeBoardState: Equatable {
    var lesson: PracticeLesson?
    /// Rounds completed so far in this lesson.
    var round = 0
    var totalRounds = 1
    var complete = false

    /// The real pointer in arena-local points, nil when it's outside.
    var pointer: CGPoint?
    /// The dwell ring's fill, 0...1.
    var dwell: Double = 0
    /// The take-control claw's brightness, 0.3...1.
    var armGlow: Double = 0.3
    /// A real mouse button is down inside the target button.
    var pressed = false

    /// The drag token, arena-normalized.
    var token: Vec2 = .zero
    var carrying = false

    var scrollOffset: Double = 0
    var scrollPhase: PracticeScrollRule.Phase = .down
    var scrollProgress: Double = 0

    /// Bumped once per success, so the celebration view restarts.
    var burst = 0
    /// Where the celebration plays, arena-normalized; nil when it's over.
    var burstAt: Vec2?
}

/// The coaching line under the hand mirror: what to do about the situation
/// the window is actually in, with the one button that can fix the worst of
/// them.
struct PracticeHint: Equatable {
    enum Action: Equatable { case grantAccessibility }

    var text: String = ""
    var action: Action?
}

// MARK: - The model

/// The practice round's brain: it owns the page, the course, the per-lesson
/// verdicts and the tracking feedback, and nothing else. It reads the
/// controller and the settings; it never writes either, never touches the
/// engine or the mouse, and never writes UserDefaults.
///
/// Three inputs drive it: the arena's real mouse events (which is what
/// completes the click, drag and scroll lessons), a 60 Hz tick (the pointer
/// poll, the dwells, and the coaching), and the controller's per-frame hand
/// feed (feedback only — the mirror, the status line, and the one lesson
/// that *is* about the hand rather than the mouse).
@MainActor
final class PracticeModel: ObservableObject {
    enum Page: Equatable {
        case intro
        case lesson(Int)
        case done
    }

    enum Outcome: Equatable { case completed, skipped }

    @Published private(set) var page: Page = .intro
    @Published private(set) var course: [PracticeLesson] = []
    @Published private(set) var outcomes: [PracticeLesson: Outcome] = [:]
    @Published private(set) var hand = PracticeHandState()
    @Published private(set) var board = PracticeBoardState()
    @Published private(set) var hint = PracticeHint()
    /// Camera-space hands for the mirror. Republished only when a new frame
    /// lands, so the 60 Hz tick doesn't re-render the canvas at twice the
    /// camera's rate.
    @Published private(set) var mirrorHands: [Hand] = []

    private(set) weak var controller: PawvisController?
    /// The arena's AppKit view: the source of both the real mouse events and
    /// the pointer poll.
    weak var arenaView: PracticeArenaView?

    /// The arena's size in points, learned from AppKit layout. Not published:
    /// the drawing side reads its own geometry, and this only feeds the
    /// normalized maths.
    private(set) var arenaSize: CGSize = .zero

    private var tick: Timer?
    private var demo: PracticeDemoHand?
    private var lastDemoFrame: TimeInterval = 0

    // Latest frame from the engine (or the demo feed).
    private var latestOverlay = OverlayState()
    private var latestHands: [Hand] = []
    private var lastFrameTime: TimeInterval = -.greatestFiniteMagnitude
    private var publishedFrameTime: TimeInterval = -.greatestFiniteMagnitude

    // Per-lesson machinery. Deliberately not published: these are verdict
    // machines, and what the window shows about them lives in `board`.
    private var armDwell = PracticeDwell(seconds: 0.6)
    private var moveDwell = PracticeDwell(seconds: 0.35)
    private var scrollRule: PracticeScrollRule?
    private var pressStartedInside = false
    private var pressedOutside = false
    private var missedDrop = false
    private var grabOffset = Vec2.zero
    private var dragResetAt: TimeInterval?
    /// When the engine's dip began, and when a real press last reached the
    /// window. Together they are the "Pawvis saw it, macOS didn't" case.
    private var dipSince: TimeInterval?
    private var lastRealPress: TimeInterval = -.greatestFiniteMagnitude
    private var autoAdvanceAt: TimeInterval?
    private var burstUntil: TimeInterval?

    // MARK: Lifecycle

    /// The window scene keeps one view alive across open/close cycles, so
    /// this resets everything rather than assuming a fresh object.
    func start(controller: PawvisController) {
        self.controller = controller
        let requested = PracticeWindow.pendingStart
        PracticeWindow.pendingStart = .intro

        demo = ProcessInfo.processInfo.environment["PAWVIS_PRACTICE_DEMO"]
            .map { PracticeDemoHand(rawValue: $0) ?? .armed }

        course = PracticeCourse.lessons(for: controller.settingsStore.settings.gestures)
        outcomes = [:]
        latestOverlay = OverlayState()
        latestHands = []
        mirrorHands = []
        lastFrameTime = -.greatestFiniteMagnitude
        publishedFrameTime = -.greatestFiniteMagnitude
        lastRealPress = -.greatestFiniteMagnitude
        dipSince = nil

        switch requested {
        case .intro:
            page = .intro
        case .done:
            // Landing straight on the summary (the eyes-on hook) shows a
            // played-through round rather than a page of blanks.
            page = course.isEmpty ? .intro : .done
            for lesson in course { outcomes[lesson] = .completed }
        case .lesson(let lesson):
            page = course.firstIndex(of: lesson).map(Page.lesson) ?? .intro
        }
        beginLesson()

        if demo == nil {
            controller.practiceFrameTap = { [weak self] overlay, hands, time in
                self?.receive(overlay: overlay, hands: hands, at: time)
            }
        }
        startTick()
    }

    func stop() {
        controller?.practiceFrameTap = nil
        tick?.invalidate()
        tick = nil
        autoAdvanceAt = nil
        burstUntil = nil
        dragResetAt = nil
    }

    private func startTick() {
        tick?.invalidate()
        // `.common` so the tick survives a menu or a live resize — the
        // pointer poll is the move lesson's only input.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    // MARK: Navigation

    func startPractice() {
        guard !course.isEmpty else { return }
        go(to: .lesson(0))
    }

    func next() {
        guard case .lesson(let index) = page else { return }
        go(to: index + 1 < course.count ? .lesson(index + 1) : .done)
    }

    func skip() {
        guard case .lesson(let index) = page, index < course.count else { return }
        if outcomes[course[index]] == nil { outcomes[course[index]] = .skipped }
        next()
    }

    func restart() {
        outcomes = [:]
        go(to: .intro)
    }

    private func go(to page: Page) {
        self.page = page
        beginLesson()
    }

    var currentLesson: PracticeLesson? {
        guard case .lesson(let index) = page, index < course.count else { return nil }
        return course[index]
    }

    /// Resets every per-lesson machine for whatever page is now current.
    private func beginLesson() {
        autoAdvanceAt = nil
        burstUntil = nil
        dragResetAt = nil
        pressStartedInside = false
        pressedOutside = false
        missedDrop = false
        scrollRule = nil
        armDwell.reset()
        moveDwell.reset()

        var next = PracticeBoardState()
        if let lesson = currentLesson {
            next.lesson = lesson
            next.totalRounds = lesson.rounds
            if lesson == .drag { next.token = PracticeTargets.dragStart(round: 0) }
        }
        board = next
        hint = PracticeHint()
    }

    // MARK: The frame feed

    private func receive(overlay: OverlayState, hands: [Hand], at time: TimeInterval) {
        latestOverlay = overlay
        latestHands = hands
        lastFrameTime = time
    }

    /// The synthetic feed: an open hand drifting in a small circle, with the
    /// requested state's flags on it.
    private func synthesize(_ state: PracticeDemoHand, at now: TimeInterval) {
        guard now - lastDemoFrame >= 1.0 / 30.0 else { return }
        lastDemoFrame = now
        lastFrameTime = now
        guard state != .none else {
            latestOverlay = OverlayState()
            latestHands = []
            return
        }
        let phase = now * 0.7
        let wrist = Vec2(0.52 + 0.045 * cos(phase), 0.74 + 0.035 * sin(phase))
        let hand = DemoHand.open(wrist: wrist)

        var overlay = OverlayState()
        var mirror = OverlayHand()
        for (joint, point) in hand.fingertips { mirror.fingertips[joint] = point }
        mirror.isPrimary = true
        overlay.hands = [mirror]
        overlay.cursor = wrist
        switch state {
        case .none:
            break
        case .found:
            overlay.armed = false
        case .armed:
            overlay.armed = true
        case .grabbed:
            overlay.grabbed = true
            overlay.closingProgress = 1
        case .dragging:
            overlay.grabbed = true
            overlay.isDragging = true
            overlay.closingProgress = 1
        case .scrolling:
            overlay.isScrolling = true
        case .right:
            overlay.rightGrabbed = true
            overlay.closingProgress = 1
        }
        latestOverlay = overlay
        latestHands = [hand]
    }

    // MARK: The tick

    private func step() {
        let now = CACurrentMediaTime()
        if let demo { synthesize(demo, at: now) }
        updateHandState(at: now)

        if let at = burstUntil, now >= at {
            burstUntil = nil
            var cleared = board
            cleared.burstAt = nil
            board = cleared
        }
        if let at = autoAdvanceAt, now >= at {
            autoAdvanceAt = nil
            next()
            return
        }

        guard let lesson = currentLesson else { return }
        var next = board
        next.pointer = arenaView?.currentPointer()
        switch lesson {
        case .takeControl: stepTakeControl(&next, at: now)
        case .move: stepMove(&next, at: now)
        case .drag: stepDrag(&next, at: now)
        case .scroll: stepScroll(&next)
        case .click, .rightClick: break // driven entirely by the real events
        }
        if next != board { board = next }

        let coached = coaching(for: lesson, at: now)
        if coached != hint { hint = coached }
    }

    private func updateHandState(at now: TimeInterval) {
        var state = PracticeHandState()
        if demo != nil {
            // A screenshot machine has no camera; the coaching states are
            // the point, so tracking is simply "on" here.
            state.trackingOn = true
        } else if let controller {
            state.trackingOn = controller.trackingActive
            state.blocked = controller.cameraFailure
                ?? controller.pauseReason
                ?? (controller.attentionPaused ? "Paused until you face the screen" : nil)
            if state.trackingOn, state.blocked == nil, now - lastFrameTime > 1.5 {
                state.blocked = "Waiting for the camera…"
            }
        }
        // Frames that stopped arriving must not leave a hand frozen in the
        // mirror; the status line already says why they stopped. Rewinding
        // the frame clock is what republishes the now-empty mirror — nothing
        // else marks the change, since no new frame ever came.
        if !state.trackingOn || now - lastFrameTime > 1.5 {
            latestOverlay = OverlayState()
            latestHands = []
            lastFrameTime = -.greatestFiniteMagnitude
        }

        state.handsInView = latestOverlay.hands.count
        state.armed = latestOverlay.armed
        state.grabbed = latestOverlay.grabbed
        state.rightGrabbed = latestOverlay.rightGrabbed
        state.middleGrabbed = latestOverlay.middleGrabbed
        state.isDragging = latestOverlay.isDragging
        state.isScrolling = latestOverlay.isScrolling
        state.closingProgress = latestOverlay.closingProgress

        let dipping = state.grabbed || state.rightGrabbed
        if dipping {
            if dipSince == nil { dipSince = now }
        } else {
            dipSince = nil
        }

        if state != hand { hand = state }
        if lastFrameTime != publishedFrameTime {
            publishedFrameTime = lastFrameTime
            mirrorHands = latestHands
        }
    }

    // MARK: Lessons driven by the tick

    private func stepTakeControl(_ next: inout PracticeBoardState, at now: TimeInterval) {
        guard !next.complete else { return }
        let holding = hand.handsInView > 0 && hand.armed
        let done = armDwell.update(inside: holding, at: now)
        next.dwell = armDwell.progress
        next.armGlow = 0.3 + 0.7 * armDwell.progress
        if done { finishRound(&next, at: Vec2(0.5, 0.5), now: now) }
    }

    private func stepMove(_ next: inout PracticeBoardState, at now: TimeInterval) {
        guard !next.complete else { return }
        let target = PracticeTargets.target(for: .move, round: next.round)
        var inside = false
        if let pointer = next.pointer, let point = normalized(pointer) {
            inside = PracticeTargets.contains(point, target: target, aspect: aspect)
        }
        let done = moveDwell.update(inside: inside, at: now)
        next.dwell = moveDwell.progress
        if done {
            moveDwell.reset()
            next.dwell = 0
            finishRound(&next, at: target, now: now)
        }
    }

    private func stepDrag(_ next: inout PracticeBoardState, at now: TimeInterval) {
        // The token stays in the slot long enough to be seen landing, then
        // the next round's token appears at its start.
        if let at = dragResetAt, now >= at {
            dragResetAt = nil
            if !next.complete { next.token = PracticeTargets.dragStart(round: next.round) }
        }
    }

    private func stepScroll(_ next: inout PracticeBoardState) {
        ensureScrollRule()
        next.scrollPhase = scrollRule?.phase ?? .down
        next.scrollProgress = scrollRule?.progress(offset: next.scrollOffset) ?? 0
    }

    private func ensureScrollRule() {
        guard scrollRule == nil, arenaSize.height > 0 else { return }
        let maxOffset = PracticeStrip.maxOffset(arenaHeight: arenaSize.height)
        scrollRule = PracticeScrollRule(downTo: maxOffset - 8, upTo: 24)
    }

    // MARK: The arena's real events

    func arenaResized(to size: CGSize) {
        guard size != arenaSize else { return }
        arenaSize = size
        // The strip's reachable travel comes from the arena's height, so a
        // rule built against the old one would ask for an offset that no
        // longer exists.
        if currentLesson == .scroll, board.scrollOffset == 0 { scrollRule = nil }
    }

    func arenaMouse(_ event: PracticeArenaEvent) {
        if case .down = event { lastRealPress = CACurrentMediaTime() }
        guard let lesson = currentLesson, !board.complete else { return }
        let now = CACurrentMediaTime()
        var next = board
        switch lesson {
        case .click: press(&next, event: event, button: .left, at: now)
        case .rightClick: press(&next, event: event, button: .right, at: now)
        case .drag: drag(&next, event: event, at: now)
        case .takeControl, .move, .scroll: break
        }
        if next != board { board = next }
    }

    func arenaScroll(by delta: Double) {
        guard currentLesson == .scroll, !board.complete, arenaSize.height > 0 else { return }
        ensureScrollRule()
        let maxOffset = PracticeStrip.maxOffset(arenaHeight: arenaSize.height)
        var next = board
        // Same sign as any macOS scroll view: a positive `scrollingDeltaY`
        // moves the content down, which is toward the top of the strip.
        next.scrollOffset = min(max(next.scrollOffset - delta, 0), maxOffset)
        let done = scrollRule?.update(offset: next.scrollOffset) ?? false
        next.scrollPhase = scrollRule?.phase ?? .down
        next.scrollProgress = scrollRule?.progress(offset: next.scrollOffset) ?? 0
        if done { finishRound(&next, at: Vec2(0.5, 0.5), now: CACurrentMediaTime()) }
        if next != board { board = next }
    }

    /// The click and right-click lessons: a real press *and* release inside
    /// the same button. Not the engine's report that a finger dipped — that
    /// is exactly the difference the round exists to show.
    private func press(
        _ next: inout PracticeBoardState, event: PracticeArenaEvent,
        button: MouseButton, at now: TimeInterval
    ) {
        let lesson = next.lesson ?? .click
        let target = PracticeTargets.target(for: lesson, round: next.round)
        switch event {
        case .down(let which, let point):
            guard which == button, let normalized = normalized(point) else { return }
            let inside = PracticeTargets.contains(normalized, target: target, aspect: aspect)
            pressStartedInside = inside
            pressedOutside = !inside
            next.pressed = inside
        case .dragged(let which, let point):
            guard which == button, pressStartedInside, let normalized = normalized(point) else { return }
            next.pressed = PracticeTargets.contains(normalized, target: target, aspect: aspect)
        case .up(let which, let point):
            guard which == button else { return }
            next.pressed = false
            guard let normalized = normalized(point) else { return }
            let inside = PracticeTargets.contains(normalized, target: target, aspect: aspect)
            if pressStartedInside, inside {
                pressedOutside = false
                finishRound(&next, at: target, now: now)
            }
            pressStartedInside = false
        }
    }

    /// The drag lesson: picked up by a real press on the token, carried by
    /// real drag events, judged on the real release.
    private func drag(
        _ next: inout PracticeBoardState, event: PracticeArenaEvent, at now: TimeInterval
    ) {
        let slot = PracticeTargets.dragSlot(round: next.round)
        switch event {
        case .down(.left, let point):
            guard let normalized = normalized(point) else { return }
            guard PracticeTargets.contains(normalized, target: next.token, aspect: aspect) else { return }
            next.carrying = true
            missedDrop = false
            grabOffset = next.token - normalized
        case .dragged(.left, let point):
            guard next.carrying, let normalized = normalized(point) else { return }
            next.token = clampToArena(normalized + grabOffset)
        case .up(.left, let point):
            guard next.carrying else { return }
            next.carrying = false
            if let normalized = normalized(point) {
                next.token = clampToArena(normalized + grabOffset)
            }
            if PracticeDrag.dropped(token: next.token, inSlot: slot, aspect: aspect) {
                next.token = slot
                finishRound(&next, at: slot, now: now)
                if !next.complete { dragResetAt = now + 0.6 }
            } else {
                next.token = PracticeTargets.dragStart(round: next.round)
                missedDrop = true
            }
        default:
            break
        }
    }

    /// One success: celebrate, count it, and finish the lesson if that was
    /// the last round.
    private func finishRound(_ next: inout PracticeBoardState, at spot: Vec2, now: TimeInterval) {
        next.round += 1
        next.burst += 1
        next.burstAt = spot
        burstUntil = now + 0.9
        pressedOutside = false
        missedDrop = false
        guard next.round >= next.totalRounds else { return }
        next.complete = true
        if let lesson = next.lesson { outcomes[lesson] = .completed }
        autoAdvanceAt = now + 1.2
    }

    // MARK: Coaching

    private func coaching(for lesson: PracticeLesson, at now: TimeInterval) -> PracticeHint {
        if board.complete { return PracticeHint(text: "Nice — that's the motion.") }
        switch lesson {
        case .takeControl:
            if hand.handsInView == 0 { return PracticeHint(text: "Face the camera, one hand up.") }
            if !hand.armed { return PracticeHint(text: "Open all four fingers wide, thumb out.") }
            return PracticeHint(text: "That's it: hold it a moment.")

        case .move:
            return PracticeHint(text: board.pointer == nil
                ? "Bring the claw into the board."
                : "Steer onto the target and hold still.")

        case .click, .rightClick:
            let dipping = lesson == .click ? hand.grabbed : hand.rightGrabbed
            // The support case AGENTS.md describes under Signing: the engine
            // sees the dip, macOS drops the synthetic click, and the app
            // still shows as enabled in Accessibility.
            if dipping, let since = dipSince, now - since >= 0.4,
               lastRealPress < since, board.pointer != nil {
                if !(controller?.accessibilityGranted ?? true) {
                    return PracticeHint(
                        text: "Pawvis saw the dip, but macOS blocked the click: grant Accessibility.",
                        action: .grantAccessibility)
                }
                return PracticeHint(
                    text: "Pawvis saw the dip, but no click arrived. If Accessibility shows Pawvis as enabled, remove it and add it again.")
            }
            if pressedOutside {
                return PracticeHint(text: "Almost: steer the claw onto the button first, then dip.")
            }
            if board.pointer == nil { return PracticeHint(text: "Bring the claw into the board.") }
            return PracticeHint(text: lesson == .click
                ? "Steer onto the button, then dip your index finger."
                : "Steer onto the button, then dip your \(rightClickFingerName).")

        case .drag:
            if board.carrying {
                return PracticeHint(text: "Keep the finger dipped… now lift it over the slot.")
            }
            if missedDrop {
                return PracticeHint(text: "Not quite: lift your finger only when the token is over the slot.")
            }
            return PracticeHint(text: "Dip your index finger on the token to pick it up.")

        case .scroll:
            let inverted = controller?.settingsStore.settings.gestures.scrollInvert ?? false
            switch scrollRule?.phase ?? .down {
            case .down:
                return PracticeHint(text: inverted
                    ? "Scroll down to reach the treat — move your hand up, since you inverted the direction in Settings."
                    : "Scroll down to reach the treat.")
            case .up, .done:
                return PracticeHint(text: inverted
                    ? "Found it! Now scroll back up to the top — move your hand down."
                    : "Found it! Now scroll back up to the top.")
            }
        }
    }

    /// The finger the user actually chose, in the word they'd use for it.
    var rightClickFingerName: String {
        let finger = controller?.settingsStore.settings.gestures.rightClickFinger ?? .little
        return finger == .little ? "pinky" : finger.rawValue
    }

    var rightClickFinger: Finger {
        controller?.settingsStore.settings.gestures.rightClickFinger ?? .little
    }

    var mirrorCamera: Bool {
        controller?.settingsStore.settings.gestures.mirrorCamera ?? true
    }

    // MARK: Geometry

    /// Width over height; every normalized radius is a fraction of the
    /// *shorter* side, which is what keeps a target's disc round.
    var aspect: Double {
        guard arenaSize.width > 0, arenaSize.height > 0 else { return 1 }
        return Double(arenaSize.width / arenaSize.height)
    }

    private func normalized(_ point: CGPoint) -> Vec2? {
        guard arenaSize.width > 0, arenaSize.height > 0 else { return nil }
        return Vec2(Double(point.x / arenaSize.width), Double(point.y / arenaSize.height))
    }

    /// Keeps a carried token's whole disc inside the board.
    private func clampToArena(_ point: Vec2) -> Vec2 {
        let radiusY = PracticeTargets.targetRadius
        let radiusX = radiusY / max(aspect, 0.001)
        return Vec2(min(max(point.x, radiusX), 1 - radiusX),
                    min(max(point.y, radiusY), 1 - radiusY))
    }
}
