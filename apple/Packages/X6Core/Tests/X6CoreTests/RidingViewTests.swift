import Foundation
import XCTest
@testable import X6Core

final class RidingViewTests: XCTestCase {
    private func varint(_ number: UInt64) -> [UInt8] {
        var value = number, result: [UInt8] = []
        repeat {
            let low = UInt8(value & 127); value >>= 7
            result.append(low | (value == 0 ? 0 : 128))
        } while value != 0
        return result
    }
    private func scalar(_ key: UInt64, _ value: UInt64) -> [UInt8] { varint(key << 3) + varint(value) }
    private func nested(_ key: UInt64, _ body: [UInt8]) -> [UInt8] { varint(key << 3 | 2) + varint(UInt64(body.count)) + body }
    private func response(battery: [UInt8]? = nil, storage: [UInt8]? = nil) -> [UInt8] {
        nested(2, (battery.map { nested(11, $0) } ?? []) + (storage.map { nested(20, $0) } ?? []))
    }

    func testTelemetryRequestOnlyAsksForBatteryAndStorage() throws {
        // Independent Python UCD2 encoder yields this same length/checksum/body.
        let packet = try UCD2.encode(.telemetry, id: 1, sequence: 1)
        XCTAssertEqual(packet.hex, "55434432010c04010d000000080002010000800000080b08143e323dbf")
        var decoder = UCD2Decoder()
        let message = try XCTUnwrap(decoder.feed(packet).first)
        XCTAssertEqual(message.code, 8)
        XCTAssertEqual(message.body, [0x08, 11, 0x08, 20])
        XCTAssertEqual(packet.count, 29)
        for split in 0...packet.count {
            var splitDecoder = UCD2Decoder()
            let result = try splitDecoder.feed(Array(packet.prefix(split))) + splitDecoder.feed(Array(packet.dropFirst(split)))
            XCTAssertEqual(result, [message])
        }
    }

    func testRealX6BatteryEventWithoutScale() throws {
        // Actual live-3 in x6-v1.1.7.json, not a synthesized battery event.
        let packet = try [UInt8](hex: "55434432010c04c10f000000032002869fa1fd00000a04080010644b45837c")
        var decoder = UCD2Decoder()
        let message = try XCTUnwrap(decoder.feed(packet).first)
        XCTAssertEqual(message.code, 8195)
        XCTAssertEqual(try CameraTelemetry.decodeBatteryNotification(message.body), 100)
    }

    func testBatteryScalingAndStorageCapacity() throws {
        let reading = try CameraTelemetry.decodeResponse(response(
            battery: scalar(2, 39) + scalar(3, 50),
            storage: scalar(2, 42_000_000_000) + scalar(3, 128_000_000_000)))
        XCTAssertEqual(reading.batteryPercent, 78)
        XCTAssertEqual(reading.freeBytes, 42_000_000_000)
        XCTAssertEqual(reading.totalBytes, 128_000_000_000)
        XCTAssertEqual(reading.cardState, 0)
    }

    func testPartialAndEmptyResponsesDoNotInventValues() throws {
        let empty = try CameraTelemetry.decodeResponse(response(battery: [], storage: []))
        XCTAssertNil(empty.batteryPercent); XCTAssertNil(empty.freeBytes); XCTAssertNil(empty.cardState)
        let partial = try CameraTelemetry.decodeResponse(response(battery: scalar(2, 78)))
        XCTAssertEqual(partial.batteryPercent, 78); XCTAssertNil(partial.freeBytes)
        XCTAssertThrowsError(try CameraTelemetry.decodeResponse([]))
    }

    func testProto3OmittedZeroRequiresSupportingFields() throws {
        let zero = try CameraTelemetry.decodeResponse(response(battery: scalar(3, 100), storage: scalar(3, 128_000_000_000)))
        XCTAssertEqual(zero.batteryPercent, 0); XCTAssertEqual(zero.freeBytes, 0)
    }

    func testInvalidPercentCapacityAndReaderCardRemainUnavailable() throws {
        for battery in [scalar(2, 101), scalar(2, 51) + scalar(3, 50), scalar(2, 50) + scalar(3, 0), scalar(2, 78) + scalar(4, 100)] {
            XCTAssertNil(try CameraTelemetry.decodeResponse(response(battery: battery)).batteryPercent)
        }
        for storage in [scalar(2, 200) + scalar(3, 100), scalar(2, 50) + scalar(3, 100) + scalar(4, 1)] {
            XCTAssertNil(try CameraTelemetry.decodeResponse(response(storage: storage)).freeBytes)
        }
    }

    func testDuplicateAndMalformedFieldsAreRejected() throws {
        XCTAssertThrowsError(try CameraTelemetry.decodeResponse(response(battery: scalar(2, 50) + scalar(2, 70))))
        XCTAssertThrowsError(try CameraTelemetry.decodeResponse(response(battery: nested(2, []))))
        XCTAssertThrowsError(try CameraTelemetry.decodeResponse([0x12, 255]))
    }

    func testTelemetryExpiresAndBatteryCannotRefreshStorageAge() {
        var display = CameraTelemetryDisplay()
        display.observe(.init(batteryPercent: 78, freeBytes: 42_000_000_000, totalBytes: 128_000_000_000, cardState: 0), at: 0)
        XCTAssertEqual(display.batteryText(at: 1, connected: true), "78%")
        XCTAssertEqual(display.storageText(at: 1, connected: true), "42.0 GB")
        XCTAssertEqual(display.storageText(at: 1, connected: false), "—")
        display.observeBattery(77, at: 74)
        XCTAssertEqual(display.batteryText(at: 76, connected: true), "77%")
        XCTAssertEqual(display.storageText(at: 76, connected: true), "—")
        display.clear()
        XCTAssertEqual(display.batteryText(at: 76, connected: true), "—")
    }

    func testCardErrorsDoNotLookLikeFreeSpace() throws {
        var display = CameraTelemetryDisplay()
        for (state, label): (UInt64, String) in [(1, "No card"), (2, "Full"), (3, "Card error"), (5, "Card error")] {
            let reading = try CameraTelemetry.decodeResponse(response(storage: scalar(1, state)))
            display.observe(reading, at: 1)
            XCTAssertEqual(display.storageText(at: 1, connected: true), label)
        }
    }

    func testDurationStartsAtCameraElapsedAndResynchronizes() {
        var clock = RecordingDuration()
        clock.observe(.init(rawState: 1, elapsed: 23), at: 100)
        XCTAssertEqual(clock.text(state: .recording, at: 101.9), "00:24")
        clock.observe(.init(rawState: 1, elapsed: 30), at: 102)
        XCTAssertEqual(clock.text(state: .recording, at: 103), "00:31")
        clock.observe(.init(rawState: 1, elapsed: 3601), at: 110)
        XCTAssertEqual(clock.text(state: .recording, at: 110), "01:00:01")
    }

    func testDurationDoesNotTickThroughLossUnknownOrRuntimeGap() {
        var clock = RecordingDuration()
        clock.observe(.init(rawState: 1, elapsed: 23), at: 100)
        XCTAssertEqual(clock.text(state: .unknown, at: 101), "--:--")
        XCTAssertEqual(clock.text(state: .recording, at: 111), "--:--")
        XCTAssertEqual(clock.text(state: .recording, at: 99), "--:--")
        clock.observe(.init(rawState: 1, elapsed: nil), at: 120)
        XCTAssertEqual(clock.text(state: .recording, at: 120), "--:--")
        clock.observe(.init(rawState: 1, elapsed: .max), at: 120)
        XCTAssertEqual(clock.text(state: .recording, at: 120), "--:--")
        clock.observe(.init(rawState: 0, elapsed: 0), at: 121)
        XCTAssertEqual(clock.text(state: .stopped, at: 121), "00:00")
    }

    @MainActor func testTelemetryFailureDoesNotChangeRecordingOrConfirmCapture() async throws {
        let link = TelemetryTestLink()
        let session = RecordingSession(link: link, delay: {})
        _ = try await session.refresh()
        var confirmations = 0; session.confirmed = { _ in confirmations += 1 }
        do { _ = try await session.refreshTelemetry(); XCTFail("Malformed optional reply") } catch {}
        XCTAssertEqual(session.state, .recording)
        XCTAssertFalse(session.busy)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(link.calls, [.status, .telemetry])
    }

    @MainActor func testCancelledTelemetryReleasesGateForStop() async throws {
        let link = TelemetryTestLink(); link.blockTelemetry = true
        let session = RecordingSession(link: link, delay: {})
        let telemetry = Task { try await session.refreshTelemetry() }
        while !session.isRefreshing { await Task.yield() }
        XCTAssertFalse(session.commandBusy, "A user command must be able to reserve its slot")
        telemetry.cancel()
        do { _ = try await telemetry.value; XCTFail("Cancellation") } catch {}
        XCTAssertFalse(session.busy)
        let result = try await session.stop()
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(link.calls, [.telemetry, .status, .stop, .status])
    }
}

@MainActor private final class TelemetryTestLink: CameraLink {
    var isReady = true
    var recording = true
    var blockTelemetry = false
    var calls: [CameraCommand] = []
    func requestReconnect() {}
    func request(_ command: CameraCommand) async throws -> [UInt8] {
        calls.append(command)
        switch command {
        case .telemetry:
            if blockTelemetry { try await Task.sleep(nanoseconds: 60_000_000_000) }
            return []
        case .status: return [0x0a, 4, 8, recording ? 1 : 0, 0x10, 23]
        case .start: recording = true; return []
        case .stop: recording = false; return []
        }
    }
}

final class WatchBatteryTests: XCTestCase {
    func testWatchBatteryPercent() {
        XCTAssertNil(WatchBattery.percent(level: -1))
        XCTAssertNil(WatchBattery.percent(level: 1.5))
        XCTAssertEqual(WatchBattery.percent(level: 0), 0)
        XCTAssertEqual(WatchBattery.percent(level: 0.644), 64)
        XCTAssertEqual(WatchBattery.percent(level: 1), 100)
    }
}
