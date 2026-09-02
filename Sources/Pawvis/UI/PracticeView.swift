import AppKit
import PawvisCore
import SwiftUI

// MARK: - The seen flag

/// The one-shot "the practice round has opened on its own once" flag. Its
/// own UserDefaults key, deliberately not a settings field — the same
/// pattern (and reason) as `FirstRun`: it records that a launch-time step
/// happened, so it survives a settings reset and never travels with an
/// exported settings blob. The rule for when it opens is pure and tested
/// (`PracticePolicy` in PawvisCore).
enum PracticeProgress {
    private static let seenKey = "Pawvis.practiceSeen"

    static var seen: Bool {
        UserDefaults.standard.bool(forKey: seenKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }
}

// MARK: - Opening the window from code

/// Which page the practice window should open on. The welcome tour and the
/// Settings buttons open on the intro; the `PAWVIS_OPEN_PRACTICE` hook can
/// land on any lesson, so each one can be looked at without playing
/// through the ones before it.
enum PracticeStartPage: Equatable {
    case intro
    case lesson(PracticeLesson)
    case done

    /// `PAWVIS_OPEN_PRACTICE`'s value: a lesson's raw name, `done`, or
    /// anything else (`1`, `intro`) for the intro.
    init(argument: String) {
        if let lesson = PracticeLesson(rawValue: argument) {
            self = .lesson(lesson)
        } else if argument == "done" {
            self = .done
        } else {
            self = .intro
        }
    }
}

/// Opening the practice window with no SwiftUI environment, same shape (and
/// same reason) as `WelcomeWindow`: the opener is captured at launch from
/// the `MenuBarExtra` label, the one view a menu-bar app always instantiates.
@MainActor
enum PracticeWindow {
    static let id = "practice"

    static var opener: OpenWindowAction?

    /// The page the next opening starts on. Set by `show(at:)` and consumed
    /// by the view when it appears; the window scene keeps one view alive
    /// across open/close cycles, so this is how a later opening can start
    /// somewhere else.
    static var pendingStart: PracticeStartPage = .intro

    static func show(at page: PracticeStartPage = .intro) {
        pendingStart = page
        opener?(id: id)
        // LSUIElement, so opening a window doesn't bring the app forward on
        // its own — see SettingsWindow for why activation happens twice.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - The window

/// The practice round: one small game per motion, played against real
/// targets with the real cursor.
///
/// The shape of every lesson page is the same — the motion animating on the
/// left, the board on the right, and what the tracker currently sees along
/// the bottom — so the only thing that changes between lessons is the
/// motion itself. The feedback strip is there on every lesson for one
/// reason: when a motion won't complete, the answer is almost always in it
/// ("no hand in view", "the dip was seen but no click arrived"), and a user
/// stuck on a lesson shouldn't have to go looking.
struct PracticeView: View {
    @ObservedObject var controller: PawvisController

    @StateObject private var model = PracticeModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// After the one-per-identity system prompt has been fired once, the
    /// accessibility button's job becomes opening the settings pane. Same
    /// rule as the welcome tour's card.
    @State private var accessibilityPrompted = false

    /// Neither permission posts a notification when granted, so poll while
    /// the window is open — the same trick as `WelcomeView`.
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.page {
            case .intro: introPage
            case .lesson(let index): lessonPage(index: index)
            case .done: donePage
            }
        }
        .padding(20)
        .frame(width: 780, height: 580)
        .tint(PawvisTheme.accentUI)
        .onAppear { model.start(controller: controller) }
        .onDisappear { model.stop() }
        .onReceive(refresh) { _ in controller.refreshPermissions() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            PracticeClaw(size: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Practice").font(.title2.bold())
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if case .lesson(let index) = model.page { progressDots(current: index) }
        }
    }

    private var headerSubtitle: String {
        switch model.page {
        case .intro:
            guard !model.course.isEmpty else { return "Nothing to practice with these settings." }
            return "Two minutes, \(model.course.count) short lessons."
        case .lesson(let index):
            guard index < model.course.count else { return "" }
            return "Lesson \(index + 1) of \(model.course.count) · \(model.course[index].title)"
        case .done:
            return "That's the round."
        }
    }

    private func progressDots(current: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(model.course.enumerated()), id: \.offset) { index, lesson in
                progressDot(index: index, lesson: lesson, current: current)
                    .help(lesson.title)
            }
        }
    }

    @ViewBuilder
    private func progressDot(index: Int, lesson: PracticeLesson, current: Int) -> some View {
        if index == current {
            Circle()
                .strokeBorder(PawvisTheme.accentUI, lineWidth: 2.5)
                .frame(width: 12, height: 12)
        } else if model.outcomes[lesson] == .completed {
            Circle().fill(PawvisTheme.accentUI).frame(width: 10, height: 10)
        } else if model.outcomes[lesson] == .skipped {
            Circle()
                .strokeBorder(.secondary.opacity(0.55), lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .overlay(
                    Capsule()
                        .fill(.secondary.opacity(0.55))
                        .frame(width: 1.5, height: 13)
                        .rotationEffect(.degrees(45)))
        } else {
            Circle().fill(.quaternary).frame(width: 10, height: 10)
        }
    }

    // MARK: Intro

    private var introPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Learn the moves").font(.title3.bold())
            Text(model.course.isEmpty
                ? "The round teaches the mouse motions — pointing, clicking, dragging, scrolling — against live targets, with the tracker's view of your hand alongside. It needs cursor control switched on."
                : "Pawvis turns your hand into the mouse. This two-minute round walks you through each motion against live targets, and shows what the tracker sees the whole time. Skip any lesson, or the whole round, whenever you like.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.course.isEmpty {
                nothingToPracticeCard
            } else {
                lessonChips
                trackingCard
                accessibilityCard
            }

            Spacer(minLength: 0)
            introFooter
        }
    }

    private var lessonChips: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.course.enumerated()), id: \.offset) { index, lesson in
                HStack(spacing: 5) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tint)
                    Text(lesson.title).font(.caption.weight(.medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
            }
        }
    }

    private var nothingToPracticeCard: some View {
        card(icon: "hand.raised.slash", title: "No mouse motions to practice", trailing: {
            Button("Change in Settings…") { SettingsRouter.shared.open(.tracking) }
        }) {
            Text("Mouse control is off: you chose “custom gestures only” under Settings → Tracking, so there is nothing to practice here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trackingCard: some View {
        card(icon: "video.fill", title: "Tracking", trailing: { trackingAction }) {
            if controller.cameraPermission == .denied {
                Text("Camera access was denied, so tracking can't run and there is nothing to practice with. Enable Pawvis under Privacy & Security → Camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The round needs the camera running: your hand is what moves the cursor onto the targets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var trackingAction: some View {
        if controller.trackingActive {
            Label("On", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        } else if controller.cameraPermission == .denied {
            Button("Open System Settings…") { Permissions.openCameraSettings() }
        } else {
            Button("Start tracking") { controller.startTracking() }
        }
    }

    private var accessibilityCard: some View {
        card(icon: "cursorarrow.click", title: "Accessibility", trailing: { accessibilityAction }) {
            Text("Clicks need Accessibility. The claw will still move without it, but no click, drag or scroll will land — so the lessons after this one can't complete.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var accessibilityAction: some View {
        if controller.accessibilityGranted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Button(accessibilityPrompted ? "Open System Settings…" : "Grant Access") {
                grantAccessibility()
            }
        }
    }

    private var introFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing in here changes your settings, and closing the window costs you nothing: the round can be run again any time from Settings → Mouse or Settings → About.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip for now") { dismiss() }
                Spacer()
                if !model.course.isEmpty {
                    Button("Start practice") { model.startPractice() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: Lesson

    @ViewBuilder
    private func lessonPage(index: Int) -> some View {
        if index < model.course.count {
            let lesson = model.course[index]
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    instructions(for: lesson).frame(width: 236, alignment: .leading)
                    PracticeBoard(model: model, reduceMotion: reduceMotion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                feedbackStrip
            }
        }
    }

    private func instructions(for lesson: PracticeLesson) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            PracticeDemoView(lesson: lesson, rightClickFinger: model.rightClickFinger)
                .frame(width: 236, height: 140)
            Text(lesson.title).font(.headline)
            Text(instruction(for: lesson))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            goal(for: lesson)
            Spacer(minLength: 0)
        }
    }

    private func instruction(for lesson: PracticeLesson) -> String {
        switch lesson {
        case .takeControl:
            return "Show the camera an open hand: all four fingers up, thumb free. The claw brightens when Pawvis hands you the cursor; a brief fist parks it again."
        case .move:
            return "Move your hand and the claw follows your palm. Steer it onto each target and hold still for a beat to pop it."
        case .click:
            return "Dip your index finger, like tapping a mouse button, with the other fingers up. Lift it quickly for a clean click."
        case .drag:
            return "Dip your index finger on the token, keep it dipped while you move, and lift it over the slot."
        case .scroll:
            return "Fold your middle and ring fingers in, index and pinky up, then move your whole hand to scroll. Find the treat at the bottom of the strip, then scroll back to the top."
        case .rightClick:
            return "Dip your \(model.rightClickFingerName) finger the same way as a click (it's the finger you chose in Settings → Mouse). The claw turns blue while it's down."
        }
    }

    private func goal(for lesson: PracticeLesson) -> some View {
        let board = model.board
        let label: String
        let value: Double
        switch lesson {
        case .takeControl:
            label = board.complete ? "Cursor taken" : "Hold the open hand"
            value = board.complete ? 1 : board.dwell
        case .move:
            label = "Targets: \(board.round) of \(board.totalRounds)"
            value = Double(board.round) / Double(max(board.totalRounds, 1))
        case .click:
            label = "Buttons clicked: \(board.round) of \(board.totalRounds)"
            value = Double(board.round) / Double(max(board.totalRounds, 1))
        case .rightClick:
            label = "Right-clicks: \(board.round) of \(board.totalRounds)"
            value = Double(board.round) / Double(max(board.totalRounds, 1))
        case .drag:
            label = "Token dropped: \(board.round) of \(board.totalRounds)"
            value = Double(board.round) / Double(max(board.totalRounds, 1))
        case .scroll:
            label = board.scrollPhase == .down ? "Down to the treat" : "Back up to the top"
            value = board.scrollProgress
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
        }
    }

    // MARK: Feedback strip

    private var feedbackStrip: some View {
        HStack(alignment: .center, spacing: 14) {
            PracticeHandMirror(hands: model.mirrorHands, mirrored: model.mirrorCamera)
                .frame(width: 150, height: 94)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(model.hand.statusLine)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.hint.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.hint.action == .grantAccessibility {
                        Button(accessibilityPrompted ? "Open Settings…" : "Grant…") {
                            grantAccessibility()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            HStack(spacing: 8) {
                Button("Skip") { model.skip() }
                Button("Next") { model.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.board.complete)
            }
        }
    }

    /// The status dot follows the app's own hues: green once the cursor is
    /// armed, then the button colors — violet left, sky right, sky-300 while
    /// the scroll pose holds.
    private var statusColor: Color {
        let hand = model.hand
        guard hand.trackingOn, hand.blocked == nil, hand.handsInView > 0 else { return .secondary }
        if hand.isScrolling { return Color(nsColor: PawvisTheme.blueLight) }
        if hand.grabbed { return PawvisTheme.purpleUI }
        if hand.rightGrabbed { return Color(nsColor: PawvisTheme.blue) }
        if hand.middleGrabbed { return Color(nsColor: PawvisTheme.fuchsia) }
        return hand.armed ? .green : .secondary
    }

    // MARK: Done

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Skipping everything is a legitimate way through, and greeting
            // it with "you've got the moves" would be a small lie.
            Text(model.outcomes.values.contains(.completed)
                ? "You've got the moves"
                : "Whenever you're ready")
                .font(.title3.bold())
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.course.enumerated()), id: \.offset) { _, lesson in
                    HStack(spacing: 9) {
                        Image(systemName: model.outcomes[lesson] == .completed
                            ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(model.outcomes[lesson] == .completed
                                ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(lesson.title).font(.callout.weight(.medium))
                        Text(model.outcomes[lesson] == .completed ? "done" : "skipped")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            Text("Everything else is in the Gesture Guide: double-click, middle-click, custom gestures, voice.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            HStack {
                Button("Practice again") { model.restart() }
                Button("Open the Gesture Guide") { openWindow(id: GuideWindow.id) }
                Spacer()
                Button("Finish") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Shared pieces

    private func grantAccessibility() {
        // The system prompt only appears once per app identity; after that,
        // the useful action is the settings pane itself.
        if accessibilityPrompted {
            Permissions.openAccessibilitySettings()
        } else {
            Permissions.promptAccessibility()
            accessibilityPrompted = true
        }
        controller.refreshPermissions()
    }

    /// A requirement card in the welcome tour's style: icon and title up
    /// top, the action on the trailing edge, full-width copy below so text
    /// wraps instead of squeezing against a control column.
    private func card(
        icon: String,
        title: String,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(title).font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - The hand mirror

/// What the tracker sees, in the trainer's own language: a fingertip dot per
/// finger and a ring on the palm. Mirrored like the trainer's preview when
/// the camera is mirrored, so the panel behaves like a mirror rather than
/// like a photograph of someone else's hand.
private struct PracticeHandMirror: View {
    let hands: [Hand]
    let mirrored: Bool

    private static let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]

    var body: some View {
        GeometryReader { geo in
            let rect = Self.videoRect(in: geo.size)
            Canvas { context, _ in
                for hand in hands {
                    for (index, joint) in Self.tips.enumerated() {
                        guard let point = hand.point(for: joint, minConfidence: 0.2) else { continue }
                        let center = place(point, in: rect)
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)),
                            with: .color(PawvisTheme.fingerDotsUI[index]))
                    }
                    if let wrist = hand.point(for: .wrist, minConfidence: 0.2),
                       let knuckle = hand.point(for: .middleMCP, minConfidence: 0.2) {
                        let palm = place(wrist.midpoint(with: knuckle), in: rect)
                        context.stroke(
                            Path(ellipseIn: CGRect(
                                x: palm.x - 6.5, y: palm.y - 6.5, width: 13, height: 13)),
                            with: .color(PawvisTheme.accentUI), lineWidth: 2.5)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // One flip mirrors the whole panel, exactly as the trainer's
            // preview does: the raw camera hands are unmirrored.
            .scaleEffect(x: mirrored ? -1 : 1)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.85)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .center) {
            if hands.isEmpty {
                Text("No hand in view")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("What Pawvis sees")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(6)
        }
    }

    /// The camera is 16:9; fitting that inside the panel keeps the hand's
    /// shape honest rather than stretching it to the panel's proportions.
    private static func videoRect(in size: CGSize) -> CGRect {
        let aspect: CGFloat = 16 / 9
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }

    private func place(_ point: Vec2, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
}
