import Foundation

/// Read-only schema from the Insta360 protobuf descriptors. X6 values still
/// require comparison with the physical camera; never infer a missing reading.
public struct CameraTelemetry: Equatable, Sendable {
    public let batteryPercent: Int?
    public let freeBytes: UInt64?
    public let totalBytes: UInt64?
    public let cardState: UInt64?
    public init(batteryPercent: Int? = nil, freeBytes: UInt64? = nil,
                totalBytes: UInt64? = nil, cardState: UInt64? = nil) {
        self.batteryPercent = batteryPercent; self.freeBytes = freeBytes
        self.totalBytes = totalBytes; self.cardState = cardState
    }

    public static func decodeResponse(_ body: [UInt8]) throws -> Self {
        let envelope = try Protobuf.fields(body)
        guard let bytes = try nested(envelope, 2) else { throw ProtocolError.missingStatus }
        let options = try Protobuf.fields(bytes)
        let battery = try nested(options, 11).map { try decodeBattery($0) } ?? nil
        var free: UInt64?, total: UInt64?, state: UInt64?
        if let storage = try nested(options, 20) {
            let fields = try Protobuf.fields(storage)
            // Proto3 omits zero-valued scalars. A positive capacity establishes
            // that omitted free_space really means zero, rather than no data.
            let location = try integer(fields, 4) ?? 0
            let rawState = try integer(fields, 1) ?? 0
            let capacity = try integer(fields, 3)
            let available = try integer(fields, 2) ?? 0
            if location == 0, rawState <= 5 {
                if rawState != 0 || (capacity ?? 0) > 0 { state = rawState }
                if [0, 2].contains(rawState), let capacity, capacity > 0, available <= capacity {
                    free = available; total = capacity
                }
            }
        }
        return Self(batteryPercent: battery, freeBytes: free, totalBytes: total, cardState: state)
    }

    public static func decodeBatteryNotification(_ body: [UInt8]) throws -> Int? {
        guard let battery = try nested(Protobuf.fields(body), 1) else { return nil }
        return try decodeBattery(battery)
    }

    private static func decodeBattery(_ body: [UInt8]) throws -> Int? {
        let fields = try Protobuf.fields(body)
        guard try integer(fields, 4) != 100 else { return nil }
        let reportedLevel = try integer(fields, 2)
        // Captured X6 v1.1.7 battery event 0a0408001064 omits scale and reports
        // explicit level=100. Treat an explicit 0...100 as percent on this profile.
        guard let scale = try integer(fields, 3) else {
            guard let level = reportedLevel, level <= 100 else { return nil }
            return Int(level)
        }
        guard scale > 0, scale <= UInt32.max else { return nil }
        let level = reportedLevel ?? 0 // proto3 zero, only with explicit valid scale
        guard level <= scale else { return nil }
        return Int((level * 100 + scale / 2) / scale)
    }

    private static func integer(_ fields: [Int: [ProtobufValue]], _ key: Int) throws -> UInt64? {
        guard let values = fields[key] else { return nil }
        guard values.count == 1, case .integer(let number) = values[0] else { throw ProtocolError.malformedProtobuf }
        return number
    }
    private static func nested(_ fields: [Int: [ProtobufValue]], _ key: Int) throws -> [UInt8]? {
        guard let values = fields[key] else { return nil }
        guard values.count == 1, case .bytes(let bytes) = values[0] else { throw ProtocolError.malformedProtobuf }
        return bytes
    }
}

/// Separate timestamps prevent a battery event making old storage data fresh.
public struct CameraTelemetryDisplay: Sendable {
    private var battery: Int?
    private var storage: CameraTelemetry?
    private var batteryAt: TimeInterval?
    private var storageAt: TimeInterval?
    public init() {}
    public mutating func clear() { self = Self() }
    public mutating func observe(_ reading: CameraTelemetry, at time: TimeInterval) {
        battery = reading.batteryPercent; batteryAt = time
        storage = reading; storageAt = time
    }
    public mutating func observeBattery(_ percent: Int?, at time: TimeInterval) {
        battery = percent; batteryAt = time
    }
    public mutating func invalidateStorage() { storage = nil; storageAt = nil }
    private func fresh(_ sampled: TimeInterval?, now: TimeInterval, connected: Bool) -> Bool {
        guard connected, let sampled else { return false }
        return (0...75).contains(now - sampled)
    }
    public func batteryText(at time: TimeInterval, connected: Bool) -> String {
        guard fresh(batteryAt, now: time, connected: connected), let battery else { return "—" }
        return "\(battery)%"
    }
    public func storageText(at time: TimeInterval, connected: Bool) -> String {
        guard fresh(storageAt, now: time, connected: connected), let storage else { return "—" }
        switch storage.cardState {
        case 1: return "No card"
        case 2: return "Full"
        case 3, 4, 5: return "Card error"
        case 0:
            guard let free = storage.freeBytes else { return "—" }
            if free > 0, free < 100_000_000 { return "<0.1 GB" }
            return String(format: "%.1f GB", Double(free) / 1_000_000_000)
        default: return "—"
        }
    }
}

/// The Watch's own battery for the riding screen. WatchKit reports 0...1, or a
/// negative level while monitoring is off or the value is unknown.
public enum WatchBattery {
    public static let lowPercent = 20

    public static func percent(level: Float) -> Int? {
        guard level >= 0, level <= 1 else { return nil }
        return Int((level * 100).rounded())
    }
}
