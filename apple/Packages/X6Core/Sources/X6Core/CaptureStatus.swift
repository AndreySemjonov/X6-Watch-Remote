import Foundation

public enum ProtobufValue: Equatable, Sendable { case integer(UInt64), bytes([UInt8]) }

public enum Protobuf {
    public static func fields(_ bytes: [UInt8]) throws -> [Int: [ProtobufValue]] {
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw ProtocolError.malformedProtobuf }
                let byte = bytes[offset]; offset += 1
                if index == 9 && byte > 1 { throw ProtocolError.malformedProtobuf }
                value |= UInt64(byte & 127) << (index * 7)
                if byte < 128 { return value }
            }
            throw ProtocolError.malformedProtobuf
        }
        var result: [Int: [ProtobufValue]] = [:]
        while offset < bytes.count {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 0x1fffffff else { throw ProtocolError.malformedProtobuf }
            let number = Int(tag >> 3), wire = tag & 7
            let value: ProtobufValue
            if wire == 0 { value = .integer(try varint()) }
            else if [1, 2, 5].contains(wire) {
                let length: UInt64 = wire == 2 ? try varint() : (wire == 1 ? 8 : 4)
                guard length <= UInt64(bytes.count - offset) else { throw ProtocolError.malformedProtobuf }
                value = .bytes(Array(bytes[offset..<(offset + Int(length))])); offset += Int(length)
            } else { throw ProtocolError.malformedProtobuf }
            result[number, default: []].append(value)
        }
        return result
    }
}

public enum RecordingState: String, Sendable, Codable { case stopped, recording, unknown }

public struct CaptureStatus: Equatable, Sendable {
    public let rawState: UInt64?
    public let elapsed: UInt64?
    public var recording: RecordingState {
        switch rawState { case 0: return .stopped; case 1: return .recording; default: return .unknown }
    }
    public init(rawState: UInt64?, elapsed: UInt64?) { self.rawState = rawState; self.elapsed = elapsed }
    public static func decodeResponse(_ bytes: [UInt8]) throws -> CaptureStatus {
        let outer = try Protobuf.fields(bytes)
        guard outer[1]?.count == 1, case .bytes(let nested) = outer[1]?.first else { throw ProtocolError.missingStatus }
        return try decodeFields(nested)
    }
    public static func decodeNotification(_ bytes: [UInt8]) throws -> CaptureStatus { try decodeFields(bytes) }
    private static func decodeFields(_ bytes: [UInt8]) throws -> CaptureStatus {
        let fields = try Protobuf.fields(bytes)
        func integer(_ key: Int) throws -> UInt64? {
            guard let values = fields[key] else { return nil }
            guard values.count == 1, case .integer(let value) = values[0] else { throw ProtocolError.malformedProtobuf }
            return value
        }
        return try CaptureStatus(rawState: integer(1), elapsed: integer(2))
    }
}
