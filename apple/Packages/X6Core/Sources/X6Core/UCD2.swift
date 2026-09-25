import Foundation

public enum ProtocolError: Error, Equatable, LocalizedError {
    case invalidHeader, invalidLength, checksumMismatch, unsupportedFragment, malformedProtobuf
    case invalidIdentifier, missingStatus, cameraRejected(UInt16)
    public var errorDescription: String? {
        switch self {
        case .cameraRejected(let code): return "Camera returned error \(code)."
        default: return "Unrecognized camera response (\(self))."
        }
    }
}

public struct CameraMessage: Equatable, Sendable {
    public let code: UInt16
    public let id: UInt32
    public let body: [UInt8]
    public let type: UInt8
}

public enum CameraCommand: UInt16, Sendable {
    case start = 4, stop = 5, telemetry = 8, status = 15
    /// GET_OPTIONS: repeated option_types, BATTERY_STATUS=11, STORAGE_STATE=20.
    var requestBody: [UInt8] { self == .telemetry ? [0x08, 11, 0x08, 20] : [] }
}

public enum UCD2 {
    public static let maximumPayload = 65_536
    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<32 {
                let high = crc & 0x80000000 != 0
                crc = (crc &<< 1) ^ (high ? 0x04c11db7 : 0)
            }
        }
        return crc
    }

    public static func encode(_ command: CameraCommand, id: UInt32, sequence: UInt8) throws -> [UInt8] {
        guard id > 0 && id <= 0x3fffffff else { throw ProtocolError.invalidIdentifier }
        var bytes: [UInt8] = [0x55, 0x43, 0x44, 0x32, 1, 12, 4, sequence]
        bytes += little(UInt32(9 + command.requestBody.count))
        bytes += little(UInt32(command.rawValue), count: 2) + [2]
        bytes += little(id | 0x80000000) + [0, 0]
        bytes += command.requestBody
        bytes += little(checksum(bytes))
        return bytes
    }

    static func little(_ value: UInt32, count: Int = 4) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
    }
}

public struct UCD2Decoder: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
    public mutating func feed(_ chunk: [UInt8]) throws -> [CameraMessage] {
        // Bound a single input too, before allocation. Typical ATT input <= 514 bytes.
        guard chunk.count <= (UCD2.maximumPayload + 16) * 2 else {
            reset(); throw ProtocolError.invalidLength
        }
        buffer += chunk
        do {
            var messages: [CameraMessage] = []
            while buffer.count >= 12 {
                guard Array(buffer[0..<4]) == [0x55, 0x43, 0x44, 0x32], buffer[4] == 1,
                      buffer[5] == 12, [4, 5].contains(buffer[6]) else { throw ProtocolError.invalidHeader }
                let length = Int(UCD2.uint32(buffer, 8))
                guard (9...UCD2.maximumPayload).contains(length) else { throw ProtocolError.invalidLength }
                let total = 12 + length + 4
                guard buffer.count >= total else { break }
                let packet = Array(buffer.prefix(total))
                buffer.removeFirst(total)
                guard UCD2.checksum(Array(packet.dropLast(4))) == UCD2.uint32(packet, total - 4) else {
                    throw ProtocolError.checksumMismatch
                }
                let flags = UCD2.uint32(packet, 15)
                guard packet[14] == 2, flags & 0x80000000 != 0 else { throw ProtocolError.unsupportedFragment }
                messages.append(CameraMessage(code: UInt16(packet[12]) | UInt16(packet[13]) << 8,
                    id: flags & 0x3fffffff, body: Array(packet[21..<(total - 4)]), type: packet[6]))
            }
            return messages
        } catch {
            reset()
            throw error
        }
    }
}

public extension Array where Element == UInt8 {
    init(hex: String) throws {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { throw ProtocolError.invalidLength }
        self = try stride(from: 0, to: chars.count, by: 2).map { index in
            guard let value = UInt8(String(decoding: chars[index..<(index + 2)], as: UTF8.self), radix: 16) else {
                throw ProtocolError.invalidHeader
            }
            return value
        }
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
