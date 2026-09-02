import Foundation

// MARK: - The practice round
//
// The interactive half of onboarding: a short game that teaches the mouse
// motions by having the user perform each one against real targets. Every
// rule about *what* the round asks for lives here, pure and clock-free like
// the rest of PawvisCore: which lessons a configuration can practice, where
// the targets go, how long a pointer must rest to count, what a drop or a
// scroll has to achieve, and what the tracking feedback line says. The app
// layer owns the window, the arena that receives the real mouse events, and
// the per-frame hand feed.
//
// The one design rule worth stating up front: **a lesson completes on the
// real thing.** The click lesson counts a click that actually reached the
// practice window as a mouse event, not the engine's report that the finger
// dipped; the drag lesson counts a token that was really dragged; the scroll
// lesson counts wheel events that really arrived. The engine's view of the
// hand is shown as feedback (the mini mirror and the status line), never as
// the verdict, so "Pawvis saw the dip but nothing clicked" (the Accessibility
// grant silently gone stale — the classic support case) shows up here as a
// lesson that won't complete, with the status line saying why.

/// One lesson of the practice round, in course order.
public enum PracticeLesson: String, CaseIterable, Codable, Sendable {
    /// Show an open hand to arm cursor control (open-hand trigger only).
    case takeControl
    /// Steer the claw onto a series of targets.
    case move
    /// Dip the index finger on a series of buttons.
    case click
    /// Hold the dip and carry a token into its slot.
    case drag
    /// Fold middle and ring fingers, then move the hand to scroll.
    case scroll
    /// Dip the right-click finger on a target.
    case rightClick

    /// Short label for the progress strip and the page header.
    public var title: String {
        switch self {
        case .takeControl: return "Take control"
        case .move: return "Move"
        case .click: return "Click"
        case .drag: return "Drag"
        case .scroll: return "Scroll"
        case .rightClick: return "Right-click"
        }
    }

    /// How many successes the lesson asks for before it's done. More than
    /// one for the pointing lessons so a lucky first target doesn't pass a
    /// motion the user hasn't actually got yet; one for the pose lessons,
    /// whose difficulty is the pose, not the repetition.
    public var rounds: Int {
        switch self {
        case .takeControl: return 1
        case .move: return 3
        case .click: return 3
        case .drag: return 2
        case .scroll: return 1
        case .rightClick: return 2
        }
    }

    /// The Gesture Guide panel that illustrates this lesson (`full-*`),
    /// without the right-click finger, which the app fills in from settings.
    public var panelName: String {
        switch self {
        case .takeControl: return "full-take-control"
        case .move: return "full-move"
        case .click: return "full-click"
        case .drag: return "full-drag"
        case .scroll: return "full-scroll"
        case .rightClick: return "full-right-click"
        }
    }
}

public enum PracticeCourse {
    /// The lessons this configuration can practice, in order. Follows the
    /// same settings the Gesture Guide follows: no take-control lesson
    /// without the open-hand trigger, no scroll or right-click lesson with
    /// the gesture switched off, and nothing at all in gestures-only mode,
    /// where the mouse is never touched and there is nothing to practice.
    public static func lessons(for config: GestureConfig) -> [PracticeLesson] {
        guard config.controlTrigger != .gesturesOnly else { return [] }
        var lessons: [PracticeLesson] = []
        if config.controlTrigger == .openHand { lessons.append(.takeControl) }
        lessons += [.move, .click, .drag]
        if config.scrollEnabled { lessons.append(.scroll) }
        if config.rightClickEnabled { lessons.append(.rightClick) }
        return lessons
    }
}

// MARK: - Opening on its own

public enum PracticePolicy {
    /// Whether the round opens by itself right after the welcome tour's
    /// Start button. Once per install (`seen` is the app's one-shot flag,
    /// set the moment it auto-opens, so closing the window counts as a
    /// skip and it never nags twice), and only when there is something to
    /// practice. Installs that predate the round never see it unasked:
    /// they went through first run already, and the About pane is where
    /// they find it.
    public static func opensAfterWelcome(seen: Bool, lessons: [PracticeLesson]) -> Bool {
        !seen && !lessons.isEmpty
    }
}

// MARK: - Dwell

/// A stay-inside timer: fills while `inside` holds, empties the moment it
/// breaks. The move lesson uses it so a pointer that merely crosses a target
/// doesn't pop it; the take-control lesson uses it so a one-frame arm
/// flicker doesn't pass the pose.
public struct PracticeDwell: Equatable, Sendable {
    public let seconds: TimeInterval
    /// 0 outside, rising to 1 as the dwell completes. Drives the filling
    /// ring around a target.
    public private(set) var progress: Double = 0
    private var enteredAt: TimeInterval?

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    /// Feed the current inside/outside verdict. Returns true on exactly the
    /// update that completes the dwell; the caller resets or moves on.
    @discardableResult
    public mutating func update(inside: Bool, at time: TimeInterval) -> Bool {
        guard inside else {
            enteredAt = nil
            progress = 0
            return false
        }
        let start = enteredAt ?? time
        enteredAt = start
        let elapsed = time - start
        progress = seconds > 0 ? min(max(elapsed / seconds, 0), 1) : 1
        return elapsed >= seconds
    }

    public mutating func reset() {
        enteredAt = nil
        progress = 0
    }
}

// MARK: - Targets

/// Where the targets go, arena-normalized (0...1 both axes, top-left
/// origin), in a fixed order that sweeps the arena. Fixed rather than
/// random on purpose: the round should teach reach in every direction,
/// and a screenshot of a lesson should look the same every time.
public enum PracticeTargets {
    /// Fraction of the arena's shorter side covered by a target's radius.
    public static let targetRadius: Double = 0.09
    /// Keep every target at least this far from an edge, so the target's
    /// whole disc stays inside the arena at the radius above.
    public static let edgeInset: Double = 0.16

    private static let moveSweep: [Vec2] = [
        Vec2(0.22, 0.30), Vec2(0.78, 0.66), Vec2(0.50, 0.82),
    ]
    private static let clickSweep: [Vec2] = [
        Vec2(0.74, 0.30), Vec2(0.26, 0.68), Vec2(0.58, 0.52),
    ]
    private static let rightClickSweep: [Vec2] = [
        Vec2(0.32, 0.42), Vec2(0.70, 0.62),
    ]

    /// The target for a pointing lesson's `round` (0-based). Rounds past
    /// the sweep wrap, so a lesson can never ask for a target it lacks.
    public static func target(for lesson: PracticeLesson, round: Int) -> Vec2 {
        let sweep: [Vec2]
        switch lesson {
        case .click: sweep = clickSweep
        case .rightClick: sweep = rightClickSweep
        default: sweep = moveSweep
        }
        return sweep[((round % sweep.count) + sweep.count) % sweep.count]
    }

    /// The drag lesson's token start and slot, per round: across the arena
    /// the first time, diagonally the second.
    public static func dragStart(round: Int) -> Vec2 {
        round % 2 == 0 ? Vec2(0.24, 0.50) : Vec2(0.72, 0.30)
    }

    public static func dragSlot(round: Int) -> Vec2 {
        round % 2 == 0 ? Vec2(0.76, 0.50) : Vec2(0.28, 0.72)
    }

    /// Whether an arena-normalized point lies within a target's disc.
    /// `aspect` is width/height, so the disc stays round on a non-square
    /// arena (normalized x is stretched by the aspect otherwise).
    public static func contains(
        _ point: Vec2, target: Vec2, radius: Double = targetRadius, aspect: Double = 1
    ) -> Bool {
        let dx = (point.x - target.x) * max(aspect, 1)
        let dy = (point.y - target.y) * max(1 / max(aspect, 0.001), 1)
        return (dx * dx + dy * dy).squareRoot() <= radius
    }
}

// MARK: - Drag

public enum PracticeDrag {
    /// How close (arena-normalized, shorter side) the token's center must
    /// land to the slot's center. Generous: the lesson is about holding the
    /// dip through a movement, not about pixel accuracy.
    public static let dropTolerance: Double = 0.09

    /// The drop verdict, evaluated on the real mouse-up.
    public static func dropped(
        token: Vec2, inSlot slot: Vec2, aspect: Double = 1
    ) -> Bool {
        PracticeTargets.contains(token, target: slot, radius: dropTolerance, aspect: aspect)
    }
}

// MARK: - Scroll

/// The scroll lesson's two legs: down to the treat at the bottom of the
/// strip, then back up to the top. Offsets are the strip's content offset
/// in arena points (0 = top). Two legs, because a scroll gesture the user
/// can only make in one direction is half a gesture.
public struct PracticeScrollRule: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case down, up, done
    }

    public private(set) var phase: Phase = .down
    /// The offset the down leg has to reach.
    public let downTo: Double
    /// The offset the up leg has to come back to.
    public let upTo: Double

    public init(downTo: Double, upTo: Double) {
        self.downTo = downTo
        self.upTo = upTo
    }

    /// Feed the strip's current offset. Returns true on exactly the update
    /// that completes the second leg.
    @discardableResult
    public mutating func update(offset: Double) -> Bool {
        switch phase {
        case .down:
            if offset >= downTo { phase = .up }
            return false
        case .up:
            if offset <= upTo {
                phase = .done
                return true
            }
            return false
        case .done:
            return false
        }
    }

    /// 0...1 across both legs, for the progress readout.
    public func progress(offset: Double) -> Double {
        guard downTo > upTo else { return phase == .done ? 1 : 0 }
        switch phase {
        case .down:
            return 0.5 * min(max(offset / downTo, 0), 1)
        case .up:
            let back = (downTo - offset) / (downTo - upTo)
            return 0.5 + 0.5 * min(max(back, 0), 1)
        case .done:
            return 1
        }
    }
}

// MARK: - Tracking feedback

/// What the engine currently makes of the hand, as the practice window
/// shows it. A plain mirror of the controller's published state plus the
/// per-frame overlay flags, so the status line can be decided (and tested)
/// without a window.
public struct PracticeHandState: Equatable, Sendable {
    public var trackingOn: Bool = false
    /// Why frames aren't reaching the engine while tracking is on: a camera
    /// failure, the lock-screen pause, or look-to-control holding actions
    /// closed. nil while healthy.
    public var blocked: String? = nil
    public var handsInView: Int = 0
    /// False while the open-hand trigger hasn't armed. Always true in
    /// any-hand mode.
    public var armed: Bool = true
    public var grabbed: Bool = false
    public var rightGrabbed: Bool = false
    public var middleGrabbed: Bool = false
    public var isDragging: Bool = false
    public var isScrolling: Bool = false
    /// The click gesture forming, 0...1.
    public var closingProgress: Double = 0

    public init() {}

    /// The one-line coach readout under the hand mirror: the current state
    /// of the hand, and what would move it forward. Ordered from "nothing
    /// can work" to "everything is fine", so the most blocking fact wins.
    public var statusLine: String {
        guard trackingOn else { return "Tracking is off." }
        if let blocked { return blocked }
        guard handsInView > 0 else {
            return "No hand in view. Face the camera with one hand up, fingers open."
        }
        if isScrolling { return "Scrolling. Relax your hand to let go." }
        if isDragging { return "Dragging. Lift your index finger to drop." }
        if grabbed { return "Index dipped: left button down. Lift it to finish the click." }
        if rightGrabbed { return "Right button down. Lift the finger to finish." }
        if middleGrabbed { return "Middle button down. Lift the finger to finish." }
        guard armed else {
            return "Hand found. Open all four fingers, thumb free, to take the cursor."
        }
        if closingProgress >= 0.5 { return "Dip forming. Keep the other fingers up." }
        return "You have the cursor. Move your hand to steer the claw."
    }
}
