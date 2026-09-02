import AppKit
import PawvisCore
import SwiftUI

// MARK: - Real events, not reported ones

/// One real mouse event that reached the practice window, in arena-local
/// points (origin top-left). The whole point of the round is that these are
/// what completes a lesson: a click the engine *reported* but macOS refused
/// to deliver never gets here, and the lesson stays open — which is exactly
/// the failure the window is trying to make visible.
enum PracticeArenaEvent: Equatable {
    case down(MouseButton, CGPoint)
    case dragged(MouseButton, CGPoint)
    case up(MouseButton, CGPoint)
}

/// The arena's event catcher: a transparent, flipped `NSView` sitting on top
/// of the SwiftUI board. SwiftUI gestures would do for a trackpad, but they
/// don't see a synthetic right-click or a wheel event nearly as plainly, and
/// the pointer poll needs a real view to convert screen coordinates through.
final class PracticeArenaView: NSView {
    var onMouse: (@MainActor (PracticeArenaEvent) -> Void)?
    var onScroll: (@MainActor (Double) -> Void)?
    var onSize: (@MainActor (CGSize) -> Void)?

    /// Top-left origin, matching SwiftUI's own and the normalized target
    /// coordinates in `PracticeTargets`.
    override var isFlipped: Bool { true }

    /// The practice window often isn't key when the hand clicks into it —
    /// the cursor arrived by camera, not by a focusing click — and a first
    /// click that only raises the window would never reach a lesson.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        onSize?(bounds.size)
    }

    // MARK: Buttons

    override func mouseDown(with event: NSEvent) { send(.down(.left, local(event))) }
    override func mouseDragged(with event: NSEvent) { send(.dragged(.left, local(event))) }
    override func mouseUp(with event: NSEvent) { send(.up(.left, local(event))) }

    override func rightMouseDown(with event: NSEvent) { send(.down(.right, local(event))) }
    override func rightMouseDragged(with event: NSEvent) { send(.dragged(.right, local(event))) }
    override func rightMouseUp(with event: NSEvent) { send(.up(.right, local(event))) }

    override func otherMouseDown(with event: NSEvent) { send(.down(.middle, local(event))) }
    override func otherMouseDragged(with event: NSEvent) { send(.dragged(.middle, local(event))) }
    override func otherMouseUp(with event: NSEvent) { send(.up(.middle, local(event))) }

    override func scrollWheel(with event: NSEvent) {
        // Line-based wheel events (which is what a posted CGEvent is, and
        // what a real mouse sends) carry a handful of lines where a trackpad
        // sends points; ~10 points a line is AppKit's own ballpark.
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 10
        onScroll?(Double(delta))
    }

    private func send(_ event: PracticeArenaEvent) { onMouse?(event) }

    private func local(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// The real pointer in arena-local points — nil when it's outside the
    /// board or the window isn't on screen. Polled rather than tracked: the
    /// cursor is being moved by a camera, not by this view, so mouse-moved
    /// events only arrive when the window happens to be key.
    func currentPointer() -> CGPoint? {
        guard let window, window.isVisible else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(inWindow, from: nil)
        return bounds.contains(point) ? point : nil
    }
}

private struct PracticeArenaCatcher: NSViewRepresentable {
    let model: PracticeModel

    func makeNSView(context: Context) -> PracticeArenaView {
        let view = PracticeArenaView()
        view.onMouse = { [weak model] in model?.arenaMouse($0) }
        view.onScroll = { [weak model] in model?.arenaScroll(by: $0) }
        view.onSize = { [weak model] in model?.arenaResized(to: $0) }
        model.arenaView = view
        return view
    }

    func updateNSView(_ nsView: PracticeArenaView, context: Context) {
        model.arenaView = nsView
    }
}

// MARK: - The scroll strip's geometry

/// Shared by the model (which needs the reachable travel to build the scroll
/// rule) and the board (which draws it). One source, or the lesson would ask
/// for an offset the strip can't reach.
enum PracticeStrip {
    static let width: CGFloat = 132
    /// Space above and below the strip inside the arena.
    static let inset: CGFloat = 24
    static let bandHeight: CGFloat = 44
    static let bandGap: CGFloat = 8
    static let bands = 14
    static let padding: CGFloat = 10

    static var contentHeight: CGFloat {
        padding * 2 + CGFloat(bands) * bandHeight + CGFloat(bands - 1) * bandGap
    }

    static func visibleHeight(arenaHeight: CGFloat) -> CGFloat {
        max(arenaHeight - 2 * inset, 80)
    }

    static func maxOffset(arenaHeight: CGFloat) -> Double {
        Double(max(contentHeight - visibleHeight(arenaHeight: arenaHeight), 1))
    }
}

// MARK: - The board

/// The game board: the targets, the token, the strip and the celebration,
/// with the AppKit catcher on top so real events reach the model.
struct PracticeBoard: View {
    @ObservedObject var model: PracticeModel
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.35))
                content(size: geo.size)
                    .animation(.easeOut(duration: 0.28), value: model.board.round)
                    .allowsHitTesting(false)
                if let spot = model.board.burstAt {
                    PracticeCelebration(reduceMotion: reduceMotion)
                        .id(model.board.burst)
                        .position(point(spot, in: geo.size))
                        .allowsHitTesting(false)
                }
                // Above the visuals on purpose: AppKit hit-testing has to
                // reach the catcher, and nothing below it wants a click.
                PracticeArenaCatcher(model: model)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1))
        }
        .frame(minWidth: 360, minHeight: 260)
    }

    // MARK: Per-lesson content

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        switch model.board.lesson {
        case .takeControl: takeControl(size: size)
        case .move: moveTarget(size: size)
        case .click: button(size: size, lesson: .click, tint: PawvisTheme.accentUI)
        case .rightClick: rightClick(size: size)
        case .drag: dragBoard(size: size)
        case .scroll: scrollStrip(size: size)
        case nil: EmptyView()
        }
    }

    /// The claw brightens as the open hand holds — the same "you have the
    /// cursor" signal the overlay gives, blown up so it can't be missed.
    private func takeControl(size: CGSize) -> some View {
        let radius = min(size.width, size.height) * 0.28
        return ZStack {
            Circle()
                .strokeBorder(.quaternary, lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .trim(from: 0, to: model.board.dwell)
                .stroke(PawvisTheme.accentUI,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: radius * 2, height: radius * 2)
            PracticeClaw(size: radius * 1.15)
                .foregroundStyle(.tint)
                .opacity(model.board.armGlow)
        }
        .position(x: size.width / 2, y: size.height / 2)
        .animation(.easeOut(duration: 0.12), value: model.board.armGlow)
    }

    /// A ring that fills while the real pointer rests inside it.
    private func moveTarget(size: CGSize) -> some View {
        let target = PracticeTargets.target(for: .move, round: model.board.round)
        let radius = Self.radius(in: size)
        return ZStack {
            Circle()
                .fill(PawvisTheme.accentUI.opacity(0.14))
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .strokeBorder(PawvisTheme.accentUI.opacity(0.55), lineWidth: 3)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .trim(from: 0, to: model.board.dwell)
                .stroke(PawvisTheme.accentUI,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: radius * 2 + 12, height: radius * 2 + 12)
            Circle().fill(PawvisTheme.accentUI).frame(width: 9, height: 9)
        }
        .position(point(target, in: size))
        .id(model.board.round)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.5).combined(with: .opacity),
            removal: .scale(scale: 1.8).combined(with: .opacity)))
    }

    /// A button that depresses under a *real* mouse-down.
    private func button(size: CGSize, lesson: PracticeLesson, tint: Color) -> some View {
        let target = PracticeTargets.target(for: lesson, round: model.board.round)
        let radius = Self.radius(in: size)
        let pressed = model.board.pressed
        return ZStack {
            Circle().fill(tint)
            PracticeClaw(size: radius * 0.95).foregroundStyle(.white)
        }
        .frame(width: radius * 2, height: radius * 2)
        .shadow(color: tint.opacity(pressed ? 0.15 : 0.35),
                radius: pressed ? 2 : 8, y: pressed ? 1 : 3)
        .scaleEffect(pressed ? 0.9 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .position(point(target, in: size))
        .id(model.board.round)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.5).combined(with: .opacity),
            removal: .scale(scale: 1.8).combined(with: .opacity)))
    }

    /// The right-click button, plus the little menu that pops out of it on
    /// success — blue throughout, because blue is the right button
    /// everywhere else in the app.
    private func rightClick(size: CGSize) -> some View {
        let radius = Self.radius(in: size)
        return ZStack {
            button(size: size, lesson: .rightClick, tint: Color(nsColor: PawvisTheme.blue))
            // Beside the button that was just pressed, not the next one:
            // the round has already moved on by the time this pops.
            if let spot = model.board.burstAt {
                PracticeContextCard()
                    .position(x: point(spot, in: size).x + radius + 46,
                              y: point(spot, in: size).y + 24)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.board.burstAt)
    }

    /// The token and its slot. The token follows real drag events, so what
    /// carries it is a button that genuinely stayed down.
    private func dragBoard(size: CGSize) -> some View {
        let slot = PracticeTargets.dragSlot(round: model.board.round)
        let radius = Self.radius(in: size)
        let slotRadius = PracticeDrag.dropTolerance * min(size.width, size.height)
        let carrying = model.board.carrying
        return ZStack {
            Circle()
                .strokeBorder(
                    PawvisTheme.accentUI.opacity(0.55),
                    style: StrokeStyle(lineWidth: 3, dash: [7, 6]))
                .frame(width: slotRadius * 2, height: slotRadius * 2)
                .position(point(slot, in: size))
                .id(model.board.round)
                .transition(.opacity)

            ZStack {
                Circle().fill(PawvisTheme.accentUI)
                PracticeClaw(size: radius * 0.95).foregroundStyle(.white)
            }
            .frame(width: radius * 2, height: radius * 2)
            .shadow(color: .black.opacity(carrying ? 0.35 : 0.18),
                    radius: carrying ? 12 : 5, y: carrying ? 6 : 2)
            .scaleEffect(carrying ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: carrying)
            .position(point(model.board.token, in: size))
            // A carried token must track the pointer exactly; only the snap
            // into the slot and the spring back get a spring.
            .animation(carrying ? nil : .spring(response: 0.32, dampingFraction: 0.72),
                       value: model.board.token)
        }
    }

    /// A tall list to scroll through, with the treat at the bottom. Its
    /// offset comes from real wheel events, so the lesson can only be
    /// finished by scrolling something.
    private func scrollStrip(size: CGSize) -> some View {
        let visible = PracticeStrip.visibleHeight(arenaHeight: size.height)
        let rect = CGRect(
            x: (size.width - PracticeStrip.width) / 2,
            y: (size.height - visible) / 2,
            width: PracticeStrip.width, height: visible)
        let goingDown = model.board.scrollPhase == .down
        return ZStack {
            PracticeStripCanvas(offset: model.board.scrollOffset)
                .frame(width: rect.width, height: rect.height)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .position(x: rect.midX, y: rect.midY)
            Image(systemName: goingDown ? "arrow.down" : "arrow.up")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .position(x: rect.maxX + 46, y: rect.midY)
            Text(goingDown ? "the treat is down here" : "back to the top")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 110)
                .multilineTextAlignment(.center)
                .position(x: rect.minX - 62, y: rect.midY)
        }
    }

    // MARK: Geometry

    /// A target's drawn radius: `PracticeTargets.targetRadius` of the
    /// arena's shorter side, matching the hit test's own maths.
    static func radius(in size: CGSize) -> CGFloat {
        PracticeTargets.targetRadius * min(size.width, size.height)
    }

    private func point(_ vector: Vec2, in size: CGSize) -> CGPoint {
        CGPoint(x: vector.x * size.width, y: vector.y * size.height)
    }
}

// MARK: - Pieces

/// The claw glyph, or the SF Symbol the bare binary falls back to (the art
/// is bundle-only, exactly as in the Gesture Guide).
struct PracticeClaw: View {
    let size: CGFloat

    var body: some View {
        if let claw = PracticeClawArt.claw(size: size) {
            Image(nsImage: claw).renderingMode(.template)
        } else {
            Image(systemName: "pawprint.fill").font(.system(size: size * 0.85))
        }
    }
}

/// The claw, loaded once per size. `PawvisGlyph` hands out fresh images on
/// purpose (callers resize them), but the board redraws whenever the pointer
/// moves, and reading the PNG back off disk sixty times a second is not
/// what that rule is for — the same cache the Gesture Guide keeps for its
/// panels.
@MainActor
private enum PracticeClawArt {
    private static var cache: [CGFloat: NSImage?] = [:]

    static func claw(size: CGFloat) -> NSImage? {
        if let cached = cache[size] { return cached }
        let image = PawvisGlyph.claw(size: size)
        cache[size] = image
        return image
    }
}

/// The scroll lesson's content: a column of bands with a treat at the
/// bottom, drawn in one `Canvas` because it redraws on every wheel event.
private struct PracticeStripCanvas: View {
    let offset: Double

    var body: some View {
        Canvas { context, size in
            for band in 0..<PracticeStrip.bands {
                let top = PracticeStrip.padding
                    + CGFloat(band) * (PracticeStrip.bandHeight + PracticeStrip.bandGap)
                    - offset
                guard top + PracticeStrip.bandHeight > 0, top < size.height else { continue }
                let rect = CGRect(x: 10, y: top,
                                  width: size.width - 20, height: PracticeStrip.bandHeight)
                let isTreat = band == PracticeStrip.bands - 1
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 8),
                    with: .color(isTreat
                        ? PawvisTheme.attentionUI.opacity(0.22)
                        : Color.primary.opacity(0.07)))
                if let symbol = context.resolveSymbol(id: isTreat ? "treat" : "paw") {
                    context.draw(symbol, at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
        } symbols: {
            Image(systemName: "pawprint")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .tag("paw")
            Image(systemName: "pawprint.fill")
                .font(.system(size: 21))
                .foregroundStyle(PawvisTheme.attentionUI)
                .tag("treat")
        }
    }
}

/// The right-click reward: a stand-in context menu, three grey lines in a
/// card. Not a real menu — the round must never open something the user
/// then has to dismiss.
private struct PracticeContextCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<3, id: \.self) { row in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.55))
                    .frame(width: row == 1 ? 44 : 60, height: 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

/// The success flash: a ring of accent dots pushing outward and fading.
/// Reduce Motion gets the word without the motion.
private struct PracticeCelebration: View {
    let reduceMotion: Bool
    @State private var phase: CGFloat = 0

    private static let dots = 10

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<Self.dots, id: \.self) { index in
                    let angle = Double(index) / Double(Self.dots) * 2 * .pi
                    Circle()
                        .fill(PawvisTheme.accentUI)
                        .frame(width: 8, height: 8)
                        .offset(x: cos(angle) * 58 * phase, y: sin(angle) * 58 * phase)
                        .opacity(1 - Double(phase))
                }
            }
            Text("Nice!")
                .font(.headline)
                .foregroundStyle(.tint)
                .offset(y: -38)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.55)) { phase = 1 }
        }
    }
}
