import XCTest
@testable import PawvisCore

final class CameraSelectionPolicyTests: XCTestCase {
    private typealias Candidate = CameraSelectionPolicy.Candidate

    private let builtIn = Candidate(id: "facetime", kind: .builtIn)
    private let iphone = Candidate(id: "iphone", kind: .continuity)
    private let webcam = Candidate(id: "usb", kind: .other)

    private func choose(pick: String? = nil, available: [Candidate]) -> String? {
        CameraSelectionPolicy.choose(pick: pick, available: available)
    }

    // MARK: Automatic

    func testAutomaticIsTheBuiltInCameraWhateverTheDiscoveryOrder() {
        XCTAssertEqual(choose(available: [webcam, iphone, builtIn]), "facetime")
        XCTAssertEqual(choose(available: [builtIn, webcam]), "facetime")
    }

    /// The decision this file exists for: an iPhone macOS offers is a picker
    /// entry, never a camera Pawvis switched to on its own.
    func testAutomaticNeverTakesAnIPhoneUnasked() {
        XCTAssertEqual(choose(available: [iphone, builtIn]), "facetime")
        XCTAssertEqual(choose(available: [builtIn, iphone]), "facetime")
    }

    func testAutomaticNeverTakesAWebcamUnasked() {
        XCTAssertEqual(choose(available: [webcam, builtIn]), "facetime")
    }

    /// A Mac mini: no built-in camera, so the first camera at all.
    func testNoBuiltInCameraMeansTheFirstCameraAtAll() {
        XCTAssertEqual(choose(available: [iphone, webcam]), "iphone")
        XCTAssertEqual(choose(available: [webcam, iphone]), "usb")
    }

    func testNoCameraAtAllMeansNil() {
        XCTAssertNil(choose(available: []))
        XCTAssertNil(choose(pick: "facetime", available: []))
    }

    // MARK: Explicit picks

    func testAPresentPickWins() {
        XCTAssertEqual(choose(pick: "iphone", available: [builtIn, iphone, webcam]), "iphone")
        XCTAssertEqual(choose(pick: "usb", available: [builtIn, iphone, webcam]), "usb")
        XCTAssertEqual(choose(pick: "facetime", available: [builtIn, iphone]), "facetime")
    }

    /// An unplugged pick is Automatic until it comes back: the built-in
    /// camera, not the next external thing in the list.
    func testAMissingPickFallsBackToTheBuiltInCamera() {
        XCTAssertEqual(choose(pick: "usb", available: [iphone, builtIn]), "facetime")
    }

    func testAMissingPickOnAMacWithoutABuiltInCameraTakesTheFirstCamera() {
        XCTAssertEqual(choose(pick: "usb", available: [iphone]), "iphone")
    }

    // MARK: Picker presentation

    private func presentation(
        pick: String?, name: String? = nil, available: [Candidate]
    ) -> CameraSelectionPolicy.PickPresentation {
        CameraSelectionPolicy.presentation(pick: pick, pickName: name, availableIDs: available.map(\.id))
    }

    func testNoPickPresentsAsAutomatic() {
        XCTAssertEqual(presentation(pick: nil, available: [builtIn, iphone]), .automatic)
    }

    func testAPresentPickPresentsAsConnected() {
        XCTAssertEqual(
            presentation(pick: "iphone", name: "iPhone Camera", available: [builtIn, iphone]),
            .connected(id: "iphone"))
    }

    /// The unplug case: the pick is gone, so the picker names what it is
    /// waiting for rather than showing a raw id or matching nothing at all.
    func testAnAbsentPickPresentsAsAwaitingReturnWithItsName() {
        XCTAssertEqual(
            presentation(pick: "iphone", name: "iPhone Camera", available: [builtIn]),
            .awaitingReturn(id: "iphone", name: "iPhone Camera"))
    }

    /// Picks stored before the name was remembered still present correctly;
    /// the caller supplies generic copy for a nil name.
    func testAnAbsentPickWithoutARememberedNameCarriesNoName() {
        XCTAssertEqual(
            presentation(pick: "iphone", available: [builtIn]),
            .awaitingReturn(id: "iphone", name: nil))
        XCTAssertEqual(
            presentation(pick: "iphone", name: "", available: [builtIn]),
            .awaitingReturn(id: "iphone", name: nil))
    }

    /// With no cameras at all a pick is still awaited, not silently dropped.
    func testAPickIsAwaitedEvenWithNoCamerasPresent() {
        XCTAssertEqual(
            presentation(pick: "iphone", name: "iPhone Camera", available: []),
            .awaitingReturn(id: "iphone", name: "iPhone Camera"))
    }

    // MARK: isAutomatic

    func testIsAutomaticMeansNoPickOrAPickThatIsGone() {
        XCTAssertTrue(CameraSelectionPolicy.isAutomatic(pick: nil, available: [builtIn]))
        XCTAssertTrue(CameraSelectionPolicy.isAutomatic(pick: "usb", available: [builtIn]))
        XCTAssertFalse(CameraSelectionPolicy.isAutomatic(pick: "facetime", available: [builtIn]))
    }
}
