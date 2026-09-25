import XCTest
@testable import X6Core

final class CameraSelectionTests: XCTestCase {
    func testFreshInstallSelectsSingleAdvertisedX6() {
        let camera = CameraCandidate(id: UUID(), name: "X6 ABCDEF")
        XCTAssertEqual(CameraSelection.automaticID(saved: nil, candidates: [camera, camera]), camera.id)
        XCTAssertNil(CameraSelection.automaticID(saved: nil, candidates: []))
        XCTAssertNil(CameraSelection.automaticID(saved: nil, candidates: [.init(id: UUID(), name: "Insta360 X4")]))
        XCTAssertNil(CameraSelection.automaticID(saved: nil, candidates: [.init(id: UUID(), name: "Unknown camera")]))
    }

    func testMultipleCamerasRequireChoice() {
        let cameras = [CameraCandidate(id: UUID(), name: "X6 A"), .init(id: UUID(), name: "X6 B")]
        XCTAssertNil(CameraSelection.automaticID(saved: nil, candidates: cameras))
        XCTAssertEqual(CameraSelection.automaticID(saved: cameras[1].id, candidates: cameras), cameras[1].id)
    }

    func testSavedCameraNeverFallsBackToAnotherCamera() {
        let saved = UUID()
        let other = CameraCandidate(id: UUID(), name: "X6 NEARBY")
        XCTAssertNil(CameraSelection.automaticID(saved: saved, candidates: [other]))
        XCTAssertEqual(CameraSelection.automaticID(saved: saved,
            candidates: [other, .init(id: saved, name: "Renamed camera")]), saved)
    }
}
