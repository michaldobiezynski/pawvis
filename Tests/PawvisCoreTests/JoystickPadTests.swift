import XCTest
@testable import PawvisCore

/// The joystick pad's placement maths and its settings node.
final class JoystickPadTests: XCTestCase {
    private let area = Vec2(1440, 860)
    private var inset: Double { JoystickPadConfig.margin + JoystickPadConfig.diameter / 2 }

    private func config(_ anchor: JoystickPadAnchor, custom: Vec2 = Vec2(0.5, 0.5)) -> JoystickPadConfig {
        var config = JoystickPadConfig()
        config.anchor = anchor
        config.customCentre = custom
        return config
    }

    func testDefaults() {
        let config = JoystickPadConfig()
        XCTAssertEqual(config.opacity, 0.85)
        XCTAssertEqual(config.anchor, .bottomRight)
        XCTAssertFalse(config.movable)
        XCTAssertEqual(PawvisSettings.default.joystickPad, config)
    }

    func testEveryAnchorStandsTheMarginOffTheEdges() {
        for anchor in JoystickPadAnchor.allCases where anchor != .custom {
            let centre = config(anchor).centre(inAreaOfSize: area)
            XCTAssertGreaterThanOrEqual(centre.x, inset, "\(anchor)")
            XCTAssertLessThanOrEqual(centre.x, area.x - inset, "\(anchor)")
            XCTAssertGreaterThanOrEqual(centre.y, inset, "\(anchor)")
            XCTAssertLessThanOrEqual(centre.y, area.y - inset, "\(anchor)")
        }
        XCTAssertEqual(config(.topLeft).centre(inAreaOfSize: area), Vec2(inset, area.y - inset))
        XCTAssertEqual(config(.bottomRight).centre(inAreaOfSize: area), Vec2(area.x - inset, inset))
        XCTAssertEqual(config(.centre).centre(inAreaOfSize: area), Vec2(area.x / 2, area.y / 2))
        XCTAssertEqual(config(.top).centre(inAreaOfSize: area), Vec2(area.x / 2, area.y - inset))
    }

    func testACustomCentreIsPulledInsideTheSameBounds() {
        XCTAssertEqual(config(.custom, custom: Vec2(0, 0)).centre(inAreaOfSize: area), Vec2(inset, inset))
        XCTAssertEqual(config(.custom, custom: Vec2(1, 1)).centre(inAreaOfSize: area),
                       Vec2(area.x - inset, area.y - inset))
        XCTAssertEqual(config(.custom, custom: Vec2(0.25, 0.5)).centre(inAreaOfSize: area),
                       Vec2(area.x * 0.25, area.y * 0.5), "a centre already inside is honoured exactly")
    }

    func testADragRoundTripsThroughTheCustomCentre() {
        let dropped = Vec2(300, 640)
        let custom = JoystickPadConfig.customCentre(for: dropped, inAreaOfSize: area)
        XCTAssertEqual(config(.custom, custom: custom).centre(inAreaOfSize: area).x, dropped.x, accuracy: 1e-9)
        XCTAssertEqual(config(.custom, custom: custom).centre(inAreaOfSize: area).y, dropped.y, accuracy: 1e-9)
        XCTAssertEqual(JoystickPadConfig.customCentre(for: Vec2(-50, 5000), inAreaOfSize: area), Vec2(0, 1),
                       "a point off the area clamps to its edge")
        XCTAssertEqual(JoystickPadConfig.customCentre(for: dropped, inAreaOfSize: .zero), Vec2(0.5, 0.5),
                       "a degenerate area falls back to the middle")
    }

    func testAnAreaTooSmallForTheMarginsGetsTheMiddle() {
        let tiny = Vec2(100, 100)
        XCTAssertEqual(config(.topLeft).centre(inAreaOfSize: tiny), Vec2(50, 50))
        XCTAssertEqual(config(.custom, custom: Vec2(0.9, 0.1)).centre(inAreaOfSize: tiny), Vec2(50, 50))
    }

    func testDecodingClampsAndTolerates() throws {
        let json = #"{"opacity":5,"anchor":"moon","customCentre":{"x":2,"y":-1},"movable":true}"#
        let decoded = try JSONDecoder().decode(JoystickPadConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.opacity, JoystickPadConfig.opacityRange.upperBound)
        XCTAssertEqual(decoded.anchor, .bottomRight, "an unknown anchor keeps the default")
        XCTAssertEqual(decoded.customCentre, Vec2(1, 0))
        XCTAssertTrue(decoded.movable)
    }

    func testTheSettingsTreeCarriesThePad() throws {
        var settings = PawvisSettings.default
        settings.joystickPad.opacity = 0.4
        settings.joystickPad.anchor = .custom
        settings.joystickPad.customCentre = Vec2(0.2, 0.8)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.joystickPad, settings.joystickPad)
        XCTAssertEqual(decoded, settings)

        let legacy = try JSONDecoder().decode(PawvisSettings.self, from: Data(#"{"general":{}}"#.utf8))
        XCTAssertEqual(legacy.joystickPad, JoystickPadConfig(), "a settings file from before the pad decodes to its defaults")
    }
}
