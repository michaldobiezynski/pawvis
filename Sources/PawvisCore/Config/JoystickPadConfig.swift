import Foundation

/// Where the joystick pad sits on the main display's usable area.
public enum JoystickPadAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight
    case left, centre, right
    case bottomLeft, bottom, bottomRight
    /// Dragged into place: `JoystickPadConfig.customCentre` says where.
    case custom

    public var displayName: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top"
        case .topRight: return "Top right"
        case .left: return "Left"
        case .centre: return "Centre"
        case .right: return "Right"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom right"
        case .custom: return "Where you dragged it"
        }
    }
}

/// The on-screen joystick pad: how see-through it is and where it sits.
/// Lives in the settings tree (`PawvisSettings.joystickPad`) and decodes
/// field-tolerantly like every other section.
public struct JoystickPadConfig: Codable, Equatable, Sendable {
    /// Window opacity, 0.15…1. High enough by default to read at a glance,
    /// low enough that whatever it covers still shows through.
    public var opacity: Double = 0.85
    public var anchor: JoystickPadAnchor = .bottomRight
    /// The pad's centre as a fraction of the usable area (x right, y up,
    /// from the bottom-left corner), honoured when `anchor` is `.custom`.
    public var customCentre: Vec2 = Vec2(0.5, 0.5)
    /// Whether the pad takes the mouse so it can be dragged. Transient in
    /// practice: the app locks the pad again at every launch, because an
    /// unlocked pad swallows the clicks under it.
    public var movable: Bool = false

    public init() {}

    public static let opacityRange: ClosedRange<Double> = 0.15...1.0
    /// The pad's diameter and its standoff from the screen edges, in points.
    public static let diameter: Double = 170
    public static let margin: Double = 24

    /// The pad's centre inside a usable area `size` wide and tall (origin
    /// bottom-left, y up). The disc never clips: anchors stand `margin` off
    /// the edges, and a custom centre is pulled inside the same bounds. An
    /// area too small for the margins gets the middle rather than a fight.
    public func centre(inAreaOfSize size: Vec2) -> Vec2 {
        let inset = Self.margin + Self.diameter / 2
        let low = Vec2(inset, inset)
        let high = Vec2(size.x - inset, size.y - inset)
        let mid = Vec2(size.x / 2, size.y / 2)
        func inside(_ point: Vec2) -> Vec2 {
            Vec2(high.x < low.x ? mid.x : min(max(point.x, low.x), high.x),
                 high.y < low.y ? mid.y : min(max(point.y, low.y), high.y))
        }
        switch anchor {
        case .topLeft: return inside(Vec2(low.x, high.y))
        case .top: return inside(Vec2(mid.x, high.y))
        case .topRight: return inside(Vec2(high.x, high.y))
        case .left: return inside(Vec2(low.x, mid.y))
        case .centre: return inside(mid)
        case .right: return inside(Vec2(high.x, mid.y))
        case .bottomLeft: return inside(Vec2(low.x, low.y))
        case .bottom: return inside(Vec2(mid.x, low.y))
        case .bottomRight: return inside(Vec2(high.x, low.y))
        case .custom: return inside(Vec2(customCentre.x * size.x, customCentre.y * size.y))
        }
    }

    /// The `customCentre` that puts the pad at `point` (the same space as
    /// `centre(inAreaOfSize:)`): what a drag writes back.
    public static func customCentre(for point: Vec2, inAreaOfSize size: Vec2) -> Vec2 {
        guard size.x > 0, size.y > 0 else { return Vec2(0.5, 0.5) }
        return Vec2(point.x / size.x, point.y / size.y).clampedToUnit()
    }

    enum CodingKeys: String, CodingKey {
        case opacity, anchor, customCentre, movable
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Double.self, forKey: .opacity) { opacity = v.clamped(to: Self.opacityRange) }
        if let v = try? c.decodeIfPresent(JoystickPadAnchor.self, forKey: .anchor) { anchor = v }
        if let v = try? c.decodeIfPresent(Vec2.self, forKey: .customCentre) { customCentre = v.clampedToUnit() }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .movable) { movable = v }
    }
}
