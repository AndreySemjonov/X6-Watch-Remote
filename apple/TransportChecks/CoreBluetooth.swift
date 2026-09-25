// Test double module only. Never included in the iPhone/Watch application.
import Foundation

public protocol CBCentralManagerDelegate: AnyObject {}
public protocol CBPeripheralDelegate: AnyObject {}
public enum CBManagerState: Int { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBPeripheralState: Int { case disconnected, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType { case withResponse }
public let CBAdvertisementDataLocalNameKey = "localName"
public struct CBCharacteristicProperties: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let write = Self(rawValue: 1)
    public static let notify = Self(rawValue: 2)
}
public struct CBUUID: Equatable {
    public let value: String
    public init(string: String) { value = string }
}
public struct CBError: Error {
    public enum Code { case leGattNearBackgroundNotificationLimit, leGattExceededBackgroundNotificationLimit }
    public let code: Code
    public init(code: Code) { self.code = code }
}
public final class CBCharacteristic {
    public let uuid: CBUUID
    public var properties: CBCharacteristicProperties = [.write, .notify]
    public var isNotifying = true
    public var value: Data?
    public init(_ uuid: CBUUID) { self.uuid = uuid }
}
public final class CBService {
    public let uuid: CBUUID
    public var characteristics: [CBCharacteristic]?
    public init(_ uuid: CBUUID) { self.uuid = uuid }
}
public final class CBPeripheral {
    public var identifier = UUID()
    public var name: String? = "X6 test"
    public var state: CBPeripheralState = .disconnected
    public weak var delegate: (any CBPeripheralDelegate)?
    public var services: [CBService]?
    public var writes: [Data] = []
    public var serviceDiscoveries = 0
    public init() {}
    public func discoverServices(_ ids: [CBUUID]?) { serviceDiscoveries += 1 }
    public func discoverCharacteristics(_ ids: [CBUUID]?, for service: CBService) {}
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 256 }
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) { writes.append(data) }
}
@MainActor public final class CBCentralManager {
    public static var latest: CBCentralManager!
    public weak var delegate: (any CBCentralManagerDelegate)?
    public var state: CBManagerState = .poweredOn
    public var retrieved: [CBPeripheral] = []
    public var connects = 0
    public var cancels = 0
    public var scans = 0
    public init(delegate: (any CBCentralManagerDelegate)?, queue: DispatchQueue?) {
        self.delegate = delegate; Self.latest = self
    }
    public func scanForPeripherals(withServices services: [CBUUID]?) { scans += 1 }
    public func stopScan() {}
    public func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] { retrieved }
    public func connect(_ peripheral: CBPeripheral) { connects += 1; peripheral.state = .connecting }
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancels += 1; peripheral.state = .disconnecting }
}
