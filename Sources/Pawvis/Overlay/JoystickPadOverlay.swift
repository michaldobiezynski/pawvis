import AppKit
import PawvisCore

/// The joystick pad: a small always-on-top HUD that shows the stick — its
/// centre, dead zone, throw ring and where the hand is pushing — whenever
/// the cursor is in joystick mode. Drawn like a heads-up display: thin cyan
/// rings on a dark translucent disc, a glowing puck for the hand. Click-
/// through, unless the user unlocks it to drag it somewhere else.
@MainActor
final class JoystickPadOverlay {
    private var panel: NSPanel?
    private let view = JoystickPadView()
    private var config = JoystickPadConfig()
    private var visible = false
    /// True while our own layout moves the window, so the move notification
    /// that follows is not mistaken for a drag.
    private var layingOut = false
    /// A drag ended with the pad's centre here (a fraction of the usable
    /// area), for the settings to persist.
    var onMoved: ((Vec2) -> Void)?

    var showInScreenCapture = false {
        didSet { panel?.sharingType = showInScreenCapture ? .readOnly : .none }
    }

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
    }

    func setConfig(_ config: JoystickPadConfig, tuning: GestureConfig) {
        self.config = config
        view.throwDistance = max(tuning.joystickThrow, 1e-3)
        view.deadZoneFraction = tuning.joystickDeadZone / max(tuning.joystickThrow, 1e-3)
        view.movable = config.movable
        if let panel {
            panel.alphaValue = config.opacity
            panel.ignoresMouseEvents = !config.movable
            panel.isMovableByWindowBackground = config.movable
            panel.isMovable = config.movable
        }
        layout()
        view.needsDisplay = true
    }

    func show() {
        guard !visible else { return }
        visible = true
        let panel = ensurePanel()
        layout()
        panel.orderFrontRegardless()
    }

    func hide() {
        guard visible else { return }
        visible = false
        panel?.orderOut(nil)
    }

    func render(stick: JoystickOverlay, armed: Bool, held: NSColor?) {
        guard visible else { return }
        view.offset = stick.offset
        view.deflection = stick.deflection
        view.armed = armed
        view.heldColor = held
        view.needsDisplay = true
    }

    // MARK: - Internals

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let size = JoystickPadConfig.diameter
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // One notch above the claw overlay's `.screenSaver`: the pad is the
        // one thing that must stay in view over everything, claw included.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = showInScreenCapture ? .readOnly : .none
        panel.alphaValue = config.opacity
        panel.ignoresMouseEvents = !config.movable
        panel.isMovableByWindowBackground = config.movable
        panel.isMovable = config.movable
        panel.contentView = view
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelMoved() }
        }
        self.panel = panel
        return panel
    }

    /// The pad lives on the main display, in its usable area (below the
    /// menu bar, above the Dock).
    private static var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private func layout() {
        guard let panel, let screen = Self.screen else { return }
        let area = screen.visibleFrame
        let centre = config.centre(inAreaOfSize: Vec2(area.width, area.height))
        let size = JoystickPadConfig.diameter
        let frame = NSRect(
            x: area.minX + centre.x - size / 2, y: area.minY + centre.y - size / 2,
            width: size, height: size)
        layingOut = true
        panel.setFrame(frame, display: true)
        layingOut = false
    }

    private func panelMoved() {
        guard !layingOut, config.movable, let panel, let screen = Self.screen else { return }
        let area = screen.visibleFrame
        let centre = Vec2(panel.frame.midX - area.minX, panel.frame.midY - area.minY)
        onMoved?(JoystickPadConfig.customCentre(for: centre, inAreaOfSize: Vec2(area.width, area.height)))
    }
}

// MARK: - View

/// The pad's face. Flipped so the stick's offset (screen-normalised, y
/// down) draws the way the hand moved.
final class JoystickPadView: NSView {
    var offset: Vec2 = .zero
    var deflection: Double = 0
    var armed = false
    var heldColor: NSColor?
    /// The throw in screen-normalised units: what maps onto the throw ring.
    var throwDistance = 0.25
    /// The dead zone as a fraction of the throw: the inner ring's radius.
    var deadZoneFraction = 0.16
    var movable = false

    override var isFlipped: Bool { true }

    private static let cyan = PawvisTheme.blueLight     // sky-300
    private static let ink = NSColor(hex: 0x06121F)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2 - 5
        let throwRadius = outer * 0.72
        let deadRadius = throwRadius * CGFloat(min(max(deadZoneFraction, 0), 1))
        let tint = heldColor ?? Self.cyan
        let alpha: CGFloat = armed ? 1 : 0.45

        func polar(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
        func ring(_ radius: CGFloat, width: CGFloat, color: NSColor, dash: [CGFloat] = []) {
            ctx.saveGState()
            ctx.setLineWidth(width)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                      width: radius * 2, height: radius * 2))
            ctx.strokePath()
            ctx.restoreGState()
        }
        func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat, color: NSColor) {
            ctx.saveGState()
            ctx.setLineWidth(width)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineCap(.round)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // The disc, and the outer ring with its glow.
        ctx.setFillColor(Self.ink.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: centre.x - outer, y: centre.y - outer, width: outer * 2, height: outer * 2))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 9, color: tint.withAlphaComponent(0.85 * alpha).cgColor)
        ring(outer, width: 1.5, color: tint.withAlphaComponent(0.9 * alpha))
        ctx.restoreGState()

        // Bearing ticks every 10°, long ones on the axes.
        for i in 0..<36 {
            let angle = CGFloat(i) * .pi / 18
            let long = i % 9 == 0
            line(polar(outer - (long ? 12 : 6), angle), polar(outer - 2, angle),
                 width: long ? 1.5 : 0.8,
                 color: tint.withAlphaComponent((long ? 0.8 : 0.4) * alpha))
        }

        // The throw ring (full speed) and the dead zone (no speed at all).
        ring(throwRadius, width: 1, color: tint.withAlphaComponent(0.55 * alpha), dash: [6, 4])
        if deadRadius > 2 {
            ring(deadRadius, width: 0.8, color: tint.withAlphaComponent(0.45 * alpha), dash: [1, 3])
        }
        for k in 0..<4 {
            let angle = CGFloat(k) * .pi / 2
            line(polar(deadRadius + 3, angle), polar(throwRadius - 3, angle),
                 width: 0.8, color: tint.withAlphaComponent(0.3 * alpha))
        }

        // The puck: where the hand is, relative to the throw ring.
        var puckOffset = CGPoint(x: offset.x / throwDistance * throwRadius,
                                 y: offset.y / throwDistance * throwRadius)
        let reach = hypot(puckOffset.x, puckOffset.y)
        let maxReach = outer - 8
        if reach > maxReach {
            puckOffset = CGPoint(x: puckOffset.x / reach * maxReach, y: puckOffset.y / reach * maxReach)
        }
        let puck = CGPoint(x: centre.x + puckOffset.x, y: centre.y + puckOffset.y)

        // The sweep on the outer ring: a bearing that widens with the push.
        if deflection > 0, reach > 0 {
            let bearing = atan2(puckOffset.y, puckOffset.x)
            let span = CGFloat(deflection) * .pi * 0.6
            ctx.saveGState()
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(tint.withAlphaComponent(0.95).cgColor)
            ctx.setShadow(offset: .zero, blur: 6, color: tint.cgColor)
            let steps = 24
            for s in 0...steps {
                let angle = bearing - span / 2 + span * CGFloat(s) / CGFloat(steps)
                let point = polar(outer - 3, angle)
                if s == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        if armed {
            line(centre, puck, width: 1, color: tint.withAlphaComponent(0.6))
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 12, color: tint.cgColor)
            ctx.setFillColor(tint.cgColor)
            ctx.fillEllipse(in: CGRect(x: puck.x - 7, y: puck.y - 7, width: 14, height: 14))
            ctx.restoreGState()
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: puck.x - 3, y: puck.y - 3, width: 6, height: 6))
        } else {
            // Parked: a hollow puck at rest in the middle.
            ring(6, width: 1.2, color: tint.withAlphaComponent(0.7 * alpha))
        }

        if movable {
            // Unlocked: a dashed white halo says "drag me".
            ring(outer + 2.5, width: 1.5, color: NSColor.white.withAlphaComponent(0.85), dash: [5, 4])
        }
    }
}
