import XCTest
@testable import X6Core

final class RidingFaceTests: XCTestCase {
    func testHeadlinesAreSingleAndStateSpecific() {
        XCTAssertEqual(RidingFace(control: .recording, workingTitle: "X"),
                       RidingFace(control: .recording, workingTitle: "Y"))
        XCTAssertEqual(RidingFace(control: .recording, workingTitle: "").headline, "● REC")
        XCTAssertEqual(RidingFace(control: .recording, workingTitle: "").tone, .recording)
        XCTAssertNil(RidingFace(control: .recording, workingTitle: "").hint)
        XCTAssertEqual(RidingFace(control: .stopped, workingTitle: "").headline, "STOPPED")
        XCTAssertEqual(RidingFace(control: .working, workingTitle: "STOPPING").headline, "STOPPING")
        XCTAssertEqual(RidingFace(control: .stopQueued, workingTitle: "").tone, .attention)
    }

    func testDisconnectedShowsReconnectingOnceAndOnlySpecificLinkMessages() {
        let generic = RidingFace(control: .disconnected, workingTitle: "", connectionMessage: "Connecting…")
        XCTAssertEqual(generic.headline, "RECONNECTING…")
        XCTAssertEqual(generic.hint, RecordingControl.disconnected.hint)
        XCTAssertEqual(generic.tone, .attention)
        let specific = RidingFace(control: .disconnected, workingTitle: "",
                                  connectionMessage: "Bluetooth unavailable (4)")
        XCTAssertEqual(specific.hint, "Bluetooth unavailable (4)")
    }

    func testLowThresholds() {
        XCTAssertTrue(RidingFace.batteryLow(20))
        XCTAssertFalse(RidingFace.batteryLow(21))
        XCTAssertFalse(RidingFace.batteryLow(nil))
    }

    func testCompactStorageAndLowStorage() {
        var display = CameraTelemetryDisplay()
        func reading(free: UInt64?, card: UInt64 = 0) -> CameraTelemetry {
            CameraTelemetry(batteryPercent: 55, freeBytes: free, totalBytes: 128_000_000_000, cardState: card)
        }
        display.observe(reading(free: 42_300_000_000), at: 0)
        XCTAssertEqual(display.storageShortText(at: 1, connected: true), "42G")
        XCTAssertFalse(display.storageLow(at: 1, connected: true))
        XCTAssertEqual(display.batteryPercent(at: 1, connected: true), 55)
        display.observe(reading(free: 3_200_000_000), at: 0)
        XCTAssertEqual(display.storageShortText(at: 1, connected: true), "3.2G")
        XCTAssertTrue(display.storageLow(at: 1, connected: true))
        display.observe(reading(free: nil, card: 1), at: 0)
        XCTAssertEqual(display.storageShortText(at: 1, connected: true), "No card")
        XCTAssertTrue(display.storageLow(at: 1, connected: true))
        XCTAssertEqual(display.storageShortText(at: 1, connected: false), "—")
        XCTAssertNil(display.batteryPercent(at: 1, connected: false))
    }

    /// Real GET_OPTIONS 11/20 reply from an X6 (fw 1.1.7), 2026-09-27:
    /// battery 49 %, 256 GB card with 199.2 GB free, storage location 3.
    func testRealX6OptionsReplyWithLocationThreeShowsFreeSpace() throws {
        let body: [UInt8] = try [UInt8](hex: "080b0814121d5a06080010312000a201120800108080f09be605188080a0ecb9072003")
        let reading = try CameraTelemetry.decodeResponse(body)
        XCTAssertEqual(reading.batteryPercent, 49)
        XCTAssertEqual(reading.cardState, 0)
        XCTAssertEqual(reading.freeBytes, 199_237_566_464)
        XCTAssertEqual(reading.totalBytes, 256_046_006_272)
        var display = CameraTelemetryDisplay()
        display.observe(reading, at: 0)
        XCTAssertEqual(display.storageShortText(at: 1, connected: true), "199G")
        XCTAssertEqual(display.storageText(at: 1, connected: true), "199.2 GB")
        XCTAssertFalse(display.storageLow(at: 1, connected: true))
    }

    /// Real reply to the 11/20/176 request after switching the X6 to internal
    /// storage (2026-09-27): option 20 follows the recording storage (location 2),
    /// and 176 lists internal (4.86 of 50.5 GB free) and SD (199.2 of 256 GB free).
    func testRealX6ReplyRecordingToInternalStorage() throws {
        let body: [UInt8] = try [UInt8](hex: "080b081408b00108b10112485a060800102d2000a201110800108080d08d12188080f88bbc012002820b110800108080d08d12188080f88bbc012002820b120800108080f09be605188080a0ecb9072003880b02")
        let reading = try CameraTelemetry.decodeResponse(body)
        XCTAssertEqual(reading.batteryPercent, 45)
        XCTAssertEqual(reading.storageLocation, 2)
        XCTAssertEqual(reading.freeBytes, 4_860_411_904)
        XCTAssertEqual(reading.storages.map(\.location), [2, 3])
        var display = CameraTelemetryDisplay()
        display.observe(reading, at: 0)
        XCTAssertEqual(display.storageLabel(at: 1, connected: true), "INT")
        XCTAssertEqual(display.storageShortText(at: 1, connected: true), "4.9G")
        XCTAssertFalse(display.storageLow(at: 1, connected: true))
        XCTAssertEqual(display.storageLines(at: 1, connected: true), [
            "Internal: 4.9 GB free of 50.5 GB (recording)",
            "SD card: 199.2 GB free of 256.0 GB",
        ])
        XCTAssertEqual(display.storageLabel(at: 1, connected: false), "SD")
        XCTAssertEqual(display.storageLines(at: 1, connected: false), [])
    }

    func testSdRecordingReplyWithoutStorageListIsLabelledSd() throws {
        let body: [UInt8] = try [UInt8](hex: "080b0814121d5a06080010312000a201120800108080f09be605188080a0ecb9072003")
        var display = CameraTelemetryDisplay()
        display.observe(try CameraTelemetry.decodeResponse(body), at: 0)
        XCTAssertEqual(display.storageLabel(at: 1, connected: true), "SD")
        XCTAssertEqual(display.storageLines(at: 1, connected: true), [])
    }
}
