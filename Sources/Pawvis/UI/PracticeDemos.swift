import AppKit
import PawvisCore
import SwiftUI

// MARK: - The card

/// A looping animation of one lesson's motion, for the practice window's
/// instruction column: the claw doing the thing the lesson asks for.
///
/// Every demo is a miniature of the real overlay — the same claw glyph, the
/// same ring tightening as a dip forms, the same expanding flash when a
/// button fires, the same hues (violet for the left button, sky for the
/// right, sky-300 for the scroll ring) — so what the card teaches is what
/// the screen will actually do.
///
/// Self-driven and stateless: `TimelineView(.animation)` turns the clock
/// into a phase and a `Canvas` draws that phase. Nothing to start or stop
/// when the practice window changes lesson, and no animation objects to
/// leak. Reduce Motion freezes it on one representative frame instead.
struct PracticeDemoView: View {
    let lesson: PracticeLesson
    var rightClickFinger: Finger = .little

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        clock
            .accessibilityElement()
            .accessibilityLabel(PracticeDemo.caption(for: lesson, finger: rightClickFinger))
    }

    @ViewBuilder
    private var clock: some View {
        if reduceMotion {
            PracticeDemoFrame(
                lesson: lesson, rightClickFinger: rightClickFinger,
                phase: PracticeDemo.stillPhase(for: lesson))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                PracticeDemoFrame(
                    lesson: lesson, rightClickFinger: rightClickFinger,
                    phase: PracticeDemo.phase(
                        for: lesson, at: timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }
}

/// One frame of a demo, at an explicit phase. Split out from the timeline so
/// the drawing is a pure function of (lesson, phase, size): the live card
/// feeds it a clock, and an offline renderer can feed it fixed phases and
/// look at the result.
struct PracticeDemoFrame: View {
    let lesson: PracticeLesson
    var rightClickFinger: Finger = .little
    /// 0...1 through this lesson's loop.
    let phase: Double

    var body: some View {
        Canvas { context, size in
            PracticeDemo.draw(
                lesson: lesson, finger: rightClickFinger, phase: phase,
                into: &context, size: size)
        }
    }
}

// MARK: - Timing

enum PracticeDemo {
    /// Loop length per lesson. Long enough to read as a motion rather than a
    /// twitch, short enough that a user glancing at the card sees the whole
    /// thing before they look away; the busier lessons get the extra beat.
    static func period(for lesson: PracticeLesson) -> Double {
        switch lesson {
        case .takeControl: return 3.6
        case .move: return 3.6
        case .click: return 3.2
        case .drag: return 4.0
        case .scroll: return 3.8
        case .rightClick: return 3.4
        }
    }

    static func phase(for lesson: PracticeLesson, at time: TimeInterval) -> Double {
        let span = period(for: lesson)
        return time.truncatingRemainder(dividingBy: span) / span
    }

    /// The frame Reduce Motion freezes on: the moment that says most about
    /// the lesson — the hand open and the claw lit, the button flashing, the
    /// token mid-carry.
    static func stillPhase(for lesson: PracticeLesson) -> Double {
        switch lesson {
        case .takeControl: return 0.55
        case .move: return 0.44
        case .click: return 0.50
        case .drag: return 0.46
        case .scroll: return 0.30
        case .rightClick: return 0.60
        }
    }

    static func caption(for lesson: PracticeLesson, finger: Finger) -> String {
        switch lesson {
        case .takeControl:
            return "Animation: a hand opens and the claw cursor lights up."
        case .move:
            return "Animation: the claw glides from target to target."
        case .click:
            return "Animation: the ring tightens, the claw closes purple, and the button flashes."
        case .drag:
            return "Animation: the claw closes on a token and carries it into its slot."
        case .scroll:
            return "Animation: the claw parks inside a blue ring"
                + " while the list scrolls down and back up."
        case .rightClick:
            return "Animation: the \(name(of: finger)) finger dips, the claw turns blue,"
                + " and a menu pops open."
        }
    }

    /// How the app names a finger to the user — "pinky", not "little",
    /// matching the Gesture Guide.
    static func name(of finger: Finger) -> String {
        finger == .little ? "pinky" : finger.rawValue
    }

    // MARK: The scene

    static func draw(
        lesson: PracticeLesson, finger: Finger, phase: Double,
        into context: inout GraphicsContext, size: CGSize
    ) {
        let stage = Path(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerRadius: min(12, min(size.width, size.height) * 0.09))
        context.fill(
            stage,
            with: .linearGradient(
                Gradient(colors: [Ink.stageTop, Ink.stageBottom]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))
        context.stroke(stage, with: .color(Ink.hairline), lineWidth: 1)
        context.clip(to: stage)

        // Everything below is laid out in the design box and scaled to fit,
        // so one set of coordinates serves any card size.
        let unit = min(size.width / Demo.width, size.height / Demo.height)
        context.translateBy(
            x: (size.width - Demo.width * unit) / 2,
            y: (size.height - Demo.height * unit) / 2)
        context.scaleBy(x: unit, y: unit)

        drawPanel(&context, lesson: lesson, finger: finger)

        switch lesson {
        case .takeControl: drawTakeControl(&context, phase: phase)
        case .move: drawMove(&context, phase: phase)
        case .click:
            drawPress(
                &context, phase: phase, button: Demo.clickButton,
                tint: PawvisTheme.purple, clawTint: Ink.purpleLight, menu: nil)
        case .drag: drawDrag(&context, phase: phase)
        case .scroll: drawScroll(&context, phase: phase)
        case .rightClick:
            drawPress(
                &context, phase: phase, button: Demo.rightClickButton,
                tint: PawvisTheme.blue, clawTint: Ink.blueLight, menu: Demo.contextCard)
        }
    }
}

// MARK: - Layout and palette

/// The design box every demo is drawn in. The practice window gives the card
/// about 236x140 points; anything else scales.
private enum Demo {
    static let width: CGFloat = 236
    static let height: CGFloat = 140

    /// Where the motion happens, below the posed-hand panel in the corner.
    static let arena = CGRect(x: 16, y: 44, width: 204, height: 84)
    /// The Gesture Guide panel, small and dim in the top-left corner.
    static let panel = CGRect(x: 10, y: 6, width: 56, height: 56 * 48 / 104)

    static let clawSize: CGFloat = 22
    /// The overlay's own ring radii, which the demos copy: 30 relaxed,
    /// tightening to 18 as the dip completes, 24 for the scroll ring.
    static let ringOpen: CGFloat = 30
    static let ringTight: CGFloat = 18

    /// Where the claw waits between runs: low and left, far enough in that
    /// its relaxed ring still fits on the stage, and clear of the panel.
    static let clawHome = CGPoint(x: 42, y: 102)

    /// The click lesson stands on the practice arena's own middle target.
    static let clickButton = point(PracticeTargets.target(for: .click, round: 2))
    /// Right-click sits a little left of centre instead — its arena target
    /// is far enough over that the menu card would hang off the stage.
    static let rightClickButton = point(Vec2(0.46, 0.46))
    static let contextCard = CGRect(
        x: rightClickButton.x + 34, y: rightClickButton.y - 21, width: 60, height: 46)

    /// An arena-normalized point (the same coordinates the real practice
    /// arena places its targets in) in design coordinates.
    static func point(_ v: Vec2) -> CGPoint {
        CGPoint(x: arena.minX + arena.width * v.x, y: arena.minY + arena.height * v.y)
    }
}

private enum Ink {
    static let stageTop = Color(nsColor: NSColor(hex: 0x171326))
    static let stageBottom = Color(nsColor: NSColor(hex: 0x0B0912))
    static let hairline = Color.white.opacity(0.08)
    static let claw = Color.white
    static let purple = Color(nsColor: PawvisTheme.purple)
    static let purpleLight = Color(nsColor: PawvisTheme.purpleLight)
    static let blueLight = Color(nsColor: PawvisTheme.blueLight)

    /// The overlay's tightening ring: white, blending toward the button's
    /// tint as the dip forms.
    static func tightening(_ progress: Double, toward tint: NSColor) -> Color {
        let blended = NSColor.white.blended(withFraction: CGFloat(progress), of: tint)
        return Color(nsColor: blended ?? tint)
    }
}

// MARK: - Easing

private func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

/// Progress through one window of the loop: 0 before it starts, 1 after it
/// ends. Every beat below is expressed this way, so a lesson's timeline
/// reads as a list of windows.
private func window(_ phase: Double, _ start: Double, _ end: Double) -> Double {
    guard end > start else { return phase >= end ? 1 : 0 }
    return clamp01((phase - start) / (end - start))
}

/// Smoothstep — ease-in-out, the curve all of this moves on.
private func ease(_ t: Double) -> Double {
    let t = clamp01(t)
    return t * t * (3 - 2 * t)
}

private func eased(_ phase: Double, _ start: Double, _ end: Double) -> Double {
    ease(window(phase, start, end))
}

/// Settles on 1 after a single small overshoot — the snap into a slot.
private func easeOutBack(_ t: Double) -> Double {
    let t = clamp01(t)
    let pull = 1.70158
    let u = t - 1
    return 1 + (pull + 1) * u * u * u + pull * u * u
}

/// 0 → 1 → 0 across a window: a beat that fades in and back out.
private func bell(_ phase: Double, _ start: Double, _ end: Double) -> Double {
    sin(.pi * window(phase, start, end))
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
}

// MARK: - Shared drawing

private func disc(_ center: CGPoint, _ radius: CGFloat) -> Path {
    Path(
        ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
}

/// The claw cursor, drawn the way the overlay draws it: the template glyph,
/// tinted — white while pointing, the button's hue while a button is down,
/// and the closed glyph (claws retracted) for the down state.
private func drawClaw(
    _ context: inout GraphicsContext, at center: CGPoint,
    closed: Bool = false, tint: Color = Ink.claw, opacity: Double = 1
) {
    let side = Demo.clawSize * (closed && ClawArt.closed == nil ? 0.85 : 1)
    let box = CGRect(
        x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    context.drawLayer { layer in
        layer.opacity = opacity
        guard let glyph = closed ? (ClawArt.closed ?? ClawArt.open) : ClawArt.open else {
            drawPaw(&layer, in: box, tint: tint)
            return
        }
        let image = layer.resolve(Image(nsImage: glyph).renderingMode(.template))
        // A dark copy under the tinted one, the same trick the overlay uses:
        // a purple claw on a purple button needs an edge.
        stencil(&layer, image, in: box.offsetBy(dx: 1, dy: 1.5), color: .black.opacity(0.5))
        stencil(&layer, image, in: box, color: tint)
    }
}

/// Draws a template image as one flat color. The art carries its own colors
/// and `ResolvedImage.shading` does not tint an `NSImage`-backed image (the
/// closed claw came out white over a purple button), so its alpha becomes a
/// clip and the color is filled through it — which is how template
/// rendering works everywhere else in the app.
private func stencil(
    _ context: inout GraphicsContext, _ image: GraphicsContext.ResolvedImage,
    in box: CGRect, color: Color
) {
    context.drawLayer { layer in
        layer.clipToLayer { mask in mask.draw(image, in: box) }
        layer.fill(Path(box), with: .color(color))
    }
}

/// The fallback cursor: a little paw, for the bare binary, which has no
/// bundle and therefore no glyph.
private func drawPaw(_ context: inout GraphicsContext, in box: CGRect, tint: Color) {
    let w = box.width, h = box.height
    var paw = Path()
    paw.addEllipse(
        in: CGRect(x: box.minX + w * 0.16, y: box.minY + h * 0.40,
                   width: w * 0.68, height: h * 0.52))
    let toe = w * 0.21
    for spot in [CGPoint(x: 0.12, y: 0.16), CGPoint(x: 0.40, y: 0.05),
                 CGPoint(x: 0.67, y: 0.16)] {
        paw.addEllipse(
            in: CGRect(x: box.minX + w * spot.x, y: box.minY + h * spot.y,
                       width: toe, height: toe))
    }
    context.stroke(paw, with: .color(.black.opacity(0.55)), lineWidth: max(w * 0.09, 1))
    context.fill(paw, with: .color(tint))
}

/// The ring around the claw: the overlay's countdown and button-down cue in
/// one. `progress` tightens it, `tint` is the button it is forming.
private func drawClawRing(
    _ context: inout GraphicsContext, at center: CGPoint, progress: Double,
    down: Bool, tint: NSColor, opacity: Double, downRadius: CGFloat = Demo.ringTight + 1
) {
    guard opacity > 0.01 else { return }
    let radius = down ? downRadius : lerp(Demo.ringOpen, Demo.ringTight, progress)
    let ring = disc(center, radius)
    context.drawLayer { layer in
        layer.opacity = opacity * (down ? 1 : 0.5 + 0.5 * progress)
        if down {
            layer.fill(ring, with: .color(Color(nsColor: tint).opacity(0.35)))
            layer.stroke(ring, with: .color(Color(nsColor: tint)), lineWidth: 3.5)
        } else {
            layer.stroke(ring, with: .color(Ink.tightening(progress, toward: tint)), lineWidth: 2.5)
        }
    }
}

/// The overlay's click flash: a ring expanding to about 2.5x and fading out.
/// It starts wider than the overlay's 13 points because here it has to clear
/// the held ring and the button to be seen at all.
private func drawFlash(
    _ context: inout GraphicsContext, at center: CGPoint, progress: Double, tint: NSColor
) {
    guard progress > 0, progress < 1 else { return }
    let grown = ease(progress)
    let ring = disc(center, lerp(16, 42, grown))
    context.drawLayer { layer in
        layer.opacity = 0.9 * (1 - grown)
        layer.stroke(ring, with: .color(Color(nsColor: tint)), lineWidth: 3)
    }
}

/// A simple five-finger hand: a palm disc with capsule fingers.
/// `openness` runs 0 (curled into a fist) to 1 (fingers extended).
private func drawHand(
    _ context: inout GraphicsContext, palm: CGPoint, openness: Double,
    tint: Color, opacity: Double
) {
    guard opacity > 0.01 else { return }
    let palmRadius: CGFloat = 15
    var hand = disc(palm, palmRadius)

    // index, middle, ring, little, then the thumb out to the side.
    let bones: [(angle: CGFloat, open: CGFloat, curled: CGFloat, width: CGFloat)] = [
        (-0.46, 17, 6, 5.5), (-0.16, 20, 6, 5.5), (0.15, 18, 6, 5.5),
        (0.45, 14, 5, 5), (-1.25, 13, 9, 6),
    ]
    for bone in bones {
        let dir = CGPoint(x: sin(bone.angle), y: -cos(bone.angle))
        let base = CGPoint(
            x: palm.x + dir.x * palmRadius * 0.7, y: palm.y + dir.y * palmRadius * 0.7)
        let length = lerp(bone.curled, bone.open, openness)
        var line = Path()
        line.move(to: base)
        line.addLine(to: CGPoint(x: base.x + dir.x * length, y: base.y + dir.y * length))
        hand.addPath(line.strokedPath(StrokeStyle(lineWidth: bone.width, lineCap: .round)))
    }

    context.drawLayer { layer in
        layer.opacity = opacity
        layer.fill(hand, with: .color(tint.opacity(0.16)))
        layer.stroke(hand, with: .color(tint.opacity(0.8)), lineWidth: 1.3)
    }
}

/// The lesson's posed-hand panel from the Gesture Guide, dim in the corner:
/// the still pose the animation is a moving version of. Bundle-only art, so
/// the bare binary simply has no corner mark.
private func drawPanel(
    _ context: inout GraphicsContext, lesson: PracticeLesson, finger: Finger
) {
    guard let art = ClawArt.panel(for: lesson, finger: finger) else { return }
    context.drawLayer { layer in
        layer.opacity = 0.5
        stencil(&layer, layer.resolve(Image(nsImage: art).renderingMode(.template)),
                in: Demo.panel, color: .white)
    }
    guard lesson == .rightClick else { return }
    let caption = Text(PracticeDemo.name(of: finger))
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.45))
    context.draw(caption, at: CGPoint(x: Demo.panel.midX, y: Demo.panel.maxY + 2), anchor: .top)
}

/// The bundled art, loaded once. `PawvisGlyph` hands out fresh images
/// because its callers resize them; these all draw at one size, and a demo
/// re-renders thirty times a second.
private enum ClawArt {
    static let open: NSImage? = PawvisGlyph.claw(size: Demo.clawSize)

    /// The retracted-claw glyph the overlay swaps in while a button is down.
    /// `PawvisGlyph` doesn't vend it (only the overlay's CALayer path uses
    /// it), so load it the same way here; nil outside the bundle, and
    /// `drawClaw` falls back to the open glyph scaled down.
    static let closed: NSImage? = {
        guard let url = Bundle.main.url(forResource: "claw-closed", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: Demo.clawSize, height: Demo.clawSize)
        return image
    }()

    static func panel(for lesson: PracticeLesson, finger: Finger) -> NSImage? {
        panels[panelName(for: lesson, finger: finger)]
    }

    /// Right-click's panel name carries the configured finger, exactly as
    /// the Gesture Guide's row does; every other lesson names one file.
    private static func panelName(for lesson: PracticeLesson, finger: Finger) -> String {
        lesson == .rightClick ? "\(lesson.panelName)-\(finger.rawValue)" : lesson.panelName
    }

    private static let panels: [String: NSImage] = {
        var names = PracticeLesson.allCases.map(\.panelName)
        names += Finger.allCases.map { "\(PracticeLesson.rightClick.panelName)-\($0.rawValue)" }
        var loaded: [String: NSImage] = [:]
        for name in names {
            if let art = PawvisGlyph.guidePanel(name, width: Demo.panel.width) {
                loaded[name] = art
            }
        }
        return loaded
    }()
}

// MARK: - Take control

/// A hand rises into view, opens, and the parked claw lights up; then the
/// hand closes and the claw goes back to sleep.
private func drawTakeControl(_ context: inout GraphicsContext, phase: Double) {
    let claw = CGPoint(x: Demo.arena.maxX - 42, y: Demo.arena.midY)
    let handHome = CGPoint(x: Demo.arena.minX + 52, y: Demo.arena.midY + 6)

    let lift = clamp01(eased(phase, 0, 0.13) - eased(phase, 0.91, 1))
    let palm = CGPoint(x: handHome.x, y: lerp(Demo.height + 26, handHome.y, lift))
    let openness = clamp01(eased(phase, 0.18, 0.40) - eased(phase, 0.72, 0.86))
    let armed = clamp01(eased(phase, 0.34, 0.46) - eased(phase, 0.74, 0.84))

    // The pulse that says control just landed: a shockwave off the claw,
    // thin and quick so it never reads as the click lesson's ring.
    let pulse = window(phase, 0.40, 0.64)
    if pulse > 0, pulse < 1 {
        context.drawLayer { layer in
            layer.opacity = 0.6 * pow(1 - pulse, 1.6)
            layer.stroke(
                disc(claw, lerp(11, 36, ease(pulse))), with: .color(.white), lineWidth: 1.8)
        }
    }

    drawHand(&context, palm: palm, openness: openness, tint: Ink.purpleLight, opacity: lift)
    drawClaw(&context, at: claw, opacity: lerp(0.35, 1, armed))
}

// MARK: - Move

/// The claw glides target to target; each one fills a ring, pops, and hands
/// off to the next. The targets are the practice arena's own sweep.
private func drawMove(_ context: inout GraphicsContext, phase: Double) {
    let stops = (0..<3).map { Demo.point(PracticeTargets.target(for: .move, round: $0)) }
    let leg = 0.96 / 3.0
    let index = min(Int(phase / leg), 2)
    let local = clamp01((phase - Double(index) * leg) / leg)

    let target = stops[index]
    let travel = ease(window(local, 0, 0.50))
    let filled = window(local, 0.52, 0.82)
    let pop = window(local, 0.82, 1)

    // The next target fades in as this one pops, so the eye is already
    // heading there when the claw sets off, and comes up to full as its own
    // leg starts rather than snapping on.
    let next = stops[(index + 1) % 3]
    context.drawLayer { layer in
        layer.opacity = 0.3 * window(local, 0.78, 1)
        layer.stroke(disc(next, 15), with: .color(Ink.purpleLight), lineWidth: 2)
    }

    context.drawLayer { layer in
        layer.opacity = (0.3 + 0.7 * window(local, 0, 0.15)) * (1 - pop)
        // Wide enough that the claw sits *inside* the target rather than
        // covering it.
        let radius = lerp(15, 22, ease(pop))
        layer.fill(disc(target, radius), with: .color(Ink.purpleLight.opacity(0.16)))
        layer.stroke(disc(target, radius), with: .color(Ink.purpleLight), lineWidth: 2)
    }

    if filled > 0 {
        var arc = Path()
        arc.addArc(
            center: target, radius: 20, startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * filled), clockwise: false)
        context.drawLayer { layer in
            // Leaves with the target it was filling, rather than blinking out.
            layer.opacity = 1 - pop
            layer.stroke(
                arc, with: .color(Ink.purpleLight),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    drawClaw(&context, at: lerp(stops[(index + 2) % 3], target, travel))
}

// MARK: - Click and right-click

/// One press, start to finish: the claw arrives, the ring tightens as the
/// dip forms, the claw closes and the button flashes, then everything opens
/// back up. Right-click is the same motion in sky blue with a context menu,
/// which is the whole point — the user has already learned this one.
///
/// `clawTint` is the 300-weight of the button's hue: the closed claw lands
/// on top of its own ring and button, and the 500 all but vanishes there,
/// the same reason the menu bar tints with `accent` rather than `purpleUI`.
private func drawPress(
    _ context: inout GraphicsContext, phase: Double, button: CGPoint,
    tint: NSColor, clawTint: Color, menu: CGRect?
) {
    let approach = eased(phase, 0.02, 0.22)
    let dip = window(phase, 0.24, 0.46)
    let release = eased(phase, 0.72, 0.82)
    let retreat = eased(phase, 0.86, 1)
    let down = phase >= 0.46 && phase < 0.72
    let pressed = clamp01(window(phase, 0.44, 0.48) - window(phase, 0.72, 0.78))

    let claw = lerp(lerp(Demo.clawHome, button, approach), Demo.clawHome, retreat)

    // The button, sinking under the press.
    let radius = lerp(15, 13, pressed)
    context.fill(
        disc(button, radius),
        with: .color(Color(nsColor: tint).opacity(lerp(0.18, 0.32, pressed))))
    context.stroke(disc(button, radius), with: .color(Color(nsColor: tint)), lineWidth: 2)

    drawFlash(&context, at: button, progress: window(phase, 0.46, 0.57), tint: tint)

    if let menu {
        drawContextCard(&context, in: menu, progress: window(phase, 0.46, 0.60),
                        fade: 1 - window(phase, 0.74, 0.84))
    }

    drawClawRing(
        &context, at: claw, progress: dip * (1 - release), down: down, tint: tint,
        opacity: approach * (1 - retreat))
    drawClaw(&context, at: claw, closed: down, tint: down ? clawTint : Ink.claw)
}

/// The little menu that a right-click actually produces: three grey lines on
/// a card, popping out from the target.
private func drawContextCard(
    _ context: inout GraphicsContext, in box: CGRect, progress: Double, fade: Double
) {
    guard progress > 0, fade > 0 else { return }
    let scale = lerp(0.7, 1, easeOutBack(progress))
    context.drawLayer { layer in
        layer.opacity = ease(progress) * fade
        // Grows out of its top-left, the corner nearest the target.
        layer.translateBy(x: box.minX, y: box.minY)
        layer.scaleBy(x: scale, y: scale)
        let card = Path(
            roundedRect: CGRect(x: 0, y: 0, width: box.width, height: box.height),
            cornerRadius: 6)
        layer.fill(card, with: .color(.white.opacity(0.12)))
        layer.stroke(card, with: .color(.white.opacity(0.22)), lineWidth: 1)
        for row in 0..<3 {
            let line = Path(
                roundedRect: CGRect(
                    x: 9, y: 11 + CGFloat(row) * 12, width: box.width - 18, height: 4),
                cornerRadius: 2)
            layer.fill(line, with: .color(.white.opacity(0.42)))
        }
    }
}

// MARK: - Drag

/// The claw closes on a token, carries it across, and opens over the slot;
/// the token settles in with one small overshoot.
private func drawDrag(_ context: inout GraphicsContext, phase: Double) {
    let start = Demo.point(PracticeTargets.dragStart(round: 0))
    let slot = Demo.point(PracticeTargets.dragSlot(round: 0))
    let approached = CGPoint(x: slot.x + 7, y: slot.y - 6)

    let approach = eased(phase, 0.02, 0.18)
    let grab = window(phase, 0.20, 0.30)
    let carry = eased(phase, 0.32, 0.62)
    let drop = window(phase, 0.64, 0.80)
    let release = eased(phase, 0.64, 0.72)
    let retreat = eased(phase, 0.88, 1)
    let held = phase >= 0.30 && phase < 0.66

    // The token: carried across on a lifted arc, then snapped into the slot.
    var token = lerp(start, approached, carry)
    token.y -= 9 * CGFloat(sin(.pi * carry))
    if drop > 0 { token = lerp(approached, slot, easeOutBack(drop)) }

    // The claw rides above-left of what it is carrying, the way a real
    // cursor sits over a dragged item.
    let grip = CGPoint(x: -8, y: -9)
    let carried = CGPoint(x: token.x + grip.x, y: token.y + grip.y)
    let anchor = CGPoint(x: approached.x + grip.x, y: approached.y + grip.y)
    let claw: CGPoint
    if phase < 0.30 {
        claw = lerp(Demo.clawHome, CGPoint(x: start.x + grip.x, y: start.y + grip.y), approach)
    } else if phase < 0.66 {
        claw = carried
    } else {
        claw = lerp(anchor, Demo.clawHome, retreat)
    }

    // The slot: dashed until it has something in it.
    let landed = ease(drop)
    context.stroke(
        disc(slot, 15), with: .color(Ink.purpleLight.opacity(0.45 + 0.55 * landed)),
        style: StrokeStyle(lineWidth: 2, dash: landed > 0.9 ? [] : [4, 3]))
    if landed > 0 {
        context.fill(disc(slot, 15), with: .color(Ink.purpleLight.opacity(0.14 * landed)))
    }

    // Ring first, then the token on top of it: the held ring is a filled
    // disc, and a token carried underneath it disappears. The ring leaves
    // early once the token is down, so the landing reads uncluttered.
    drawClawRing(
        &context, at: claw, progress: grab * (1 - release), down: held,
        tint: PawvisTheme.purple, opacity: approach * (1 - eased(phase, 0.72, 0.88)),
        downRadius: 22)

    // The reset: the dropped token leaves before a fresh one arrives back at
    // the start, so the loop never shows two of them side by side.
    drawToken(&context, at: token, held: held, opacity: 1 - window(phase, 0.90, 0.96))
    drawToken(&context, at: start, held: false, opacity: window(phase, 0.955, 1))

    drawClaw(&context, at: claw, closed: held, tint: held ? Ink.purpleLight : Ink.claw)
}

private func drawToken(
    _ context: inout GraphicsContext, at center: CGPoint, held: Bool, opacity: Double
) {
    guard opacity > 0.01 else { return }
    let side: CGFloat = held ? 17 : 16
    let box = CGRect(
        x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    let token = Path(roundedRect: box, cornerRadius: 5)
    context.drawLayer { layer in
        layer.opacity = opacity
        layer.fill(token, with: .color(Ink.purpleLight.opacity(held ? 0.95 : 0.8)))
        if held {
            layer.stroke(token, with: .color(Ink.purple), lineWidth: 1.5)
        }
    }
}

// MARK: - Scroll

/// The claw parks inside the sky-blue scroll ring and stays put — the point
/// of the lesson — while the hand's motion moves the list instead.
private func drawScroll(_ context: inout GraphicsContext, phase: Double) {
    let claw = CGPoint(x: Demo.arena.minX + 58, y: Demo.arena.midY)
    let strip = CGRect(x: Demo.arena.maxX - 70, y: Demo.arena.minY + 4, width: 66, height: 76)

    // Down the list first, then back up — the two legs the scroll lesson
    // itself asks for. Offset grows as the list scrolls down, which moves
    // the bands *up* past the frame.
    let offset = 40 * (eased(phase, 0.10, 0.40) - eased(phase, 0.58, 0.88))
    let goingDown = bell(phase, 0.08, 0.46)
    let goingUp = bell(phase, 0.56, 0.94)

    // The list, clipped to its own rounded frame.
    let frame = Path(roundedRect: strip, cornerRadius: 7)
    context.fill(frame, with: .color(.white.opacity(0.05)))
    context.drawLayer { layer in
        layer.clip(to: frame)
        for index in -2...6 {
            let y = strip.minY + 7 + CGFloat(index) * 20 - offset
            let band = Path(
                roundedRect: CGRect(x: strip.minX + 8, y: y, width: strip.width - 16, height: 13),
                cornerRadius: 4)
            // One band wears the scroll hue, so the travel is unmistakable.
            let marked = index == 3
            layer.fill(
                band,
                with: .color(marked ? Ink.blueLight.opacity(0.75) : .white.opacity(0.2)))
        }
    }
    context.stroke(frame, with: .color(.white.opacity(0.12)), lineWidth: 1)

    // The arrow is the *hand*, not the list: hand down scrolls down, which
    // is the mapping the Gesture Guide teaches.
    drawHandArrow(
        &context, at: CGPoint(x: (claw.x + strip.minX) / 2, y: Demo.arena.midY),
        up: goingUp > goingDown, strength: max(goingDown, goingUp))

    // The parked cursor with the overlay's scroll ring: stroke plus a 25%
    // fill, sky-300.
    let ring = disc(claw, 24)
    context.fill(ring, with: .color(Ink.blueLight.opacity(0.25)))
    context.stroke(ring, with: .color(Ink.blueLight), lineWidth: 3)
    drawClaw(&context, at: claw)
}

/// Which way the hand is moving, beside the list it is moving.
private func drawHandArrow(
    _ context: inout GraphicsContext, at center: CGPoint, up: Bool, strength: Double
) {
    let sign: CGFloat = up ? -1 : 1
    let shift = 4 * CGFloat(strength) * sign
    let tip = CGPoint(x: center.x, y: center.y + sign * 22 + shift)
    let tail = CGPoint(x: center.x, y: center.y - sign * 20 + shift)

    var arrow = Path()
    arrow.move(to: tail)
    arrow.addLine(to: tip)
    arrow.move(to: CGPoint(x: tip.x - 6, y: tip.y - sign * 7))
    arrow.addLine(to: tip)
    arrow.addLine(to: CGPoint(x: tip.x + 6, y: tip.y - sign * 7))

    context.drawLayer { layer in
        layer.opacity = 0.28 + 0.72 * strength
        layer.stroke(
            arrow, with: .color(Ink.blueLight),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
}
