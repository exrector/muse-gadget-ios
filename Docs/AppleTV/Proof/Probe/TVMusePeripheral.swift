import CoreBluetooth
import Foundation

protocol MusePeripheralDelegate: AnyObject {
    func musePeripheral(_ peripheral: MusePeripheral, didChange event: MusePeripheral.Event)
    func musePeripheral(_ peripheral: MusePeripheral, didReceive packet: Data)
}

/// The same job as the iOS MusePeripheral. The tvOS SDK refuses these classes at compile time although
/// the system has them, so everything goes through the Objective-C runtime.
final class MusePeripheral: NSObject {
    enum Event: Equatable {
        case bluetoothState(String)
        case advertising
        case subscribed(mtu: Int)
        case disconnected
        case error(String)
    }

    static let serviceUUID = CBUUID(string: "7fdd3d1c-38ea-46cf-8b46-314ecf5f240c")
    static let receiveUUID = CBUUID(string: "4d593029-28a2-4a6e-a1f0-3c2d5e8f9b01")
    static let transmitUUID = CBUUID(string: "d75dc4ca-7b2b-4e9c-8f0a-1d2e3f4a5b6c")

    weak var delegate: MusePeripheralDelegate?

    private let localName: String
    private var manager: NSObject?
    private var transmit: NSObject?
    private var subscribedCentral: NSObject?
    private var pendingPackets: [Data] = []
    private var enqueuedPacketCount = 0
    private var sentPacketCount = 0
    private var drainWaiters: [(target: Int, completion: () -> Void)] = []
    private var shouldAdvertise = false

    private(set) var transportMTU = 23

    init(localName: String) {
        self.localName = localName
        super.init()
    }

    private func make(_ className: String) -> NSObject {
        let cls = NSClassFromString(className) as! NSObject.Type
        return cls.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
    }

    private var isPoweredOn: Bool { (manager?.value(forKey: "state") as? NSNumber)?.intValue == 5 }

    private func identifier(_ central: NSObject?) -> UUID? {
        central?.value(forKey: "identifier") as? UUID
    }

    func start() {
        shouldAdvertise = true
        if manager == nil {
            manager = make("CBPeripheralManager")
                .perform(NSSelectorFromString("initWithDelegate:queue:"), with: self, with: DispatchQueue.main)?
                .takeUnretainedValue() as? NSObject
        } else if isPoweredOn {
            publishServiceIfNeeded()
        }
    }

    func stop() {
        shouldAdvertise = false
        manager?.perform(NSSelectorFromString("stopAdvertising"))
        manager?.perform(NSSelectorFromString("removeAllServices"))
        transmit = nil
        subscribedCentral = nil
        pendingPackets.removeAll()
        drainWaiters.removeAll()
    }

    func send(_ packets: [Data], completion: (() -> Void)? = nil) {
        pendingPackets.append(contentsOf: packets)
        enqueuedPacketCount += packets.count
        if let completion {
            drainWaiters.append((target: enqueuedPacketCount, completion: completion))
        }
        drain()
    }

    private func characteristic(_ id: CBUUID, properties: UInt, permissions: UInt) -> NSObject {
        typealias Init = @convention(c) (AnyObject, Selector, CBUUID, UInt, NSData?, UInt) -> Unmanaged<NSObject>
        let allocated = make("CBMutableCharacteristic")
        let selector = NSSelectorFromString("initWithType:properties:value:permissions:")
        let function = unsafeBitCast(allocated.method(for: selector), to: Init.self)
        return function(allocated, selector, id, properties, nil, permissions).takeUnretainedValue()
    }

    private func publishServiceIfNeeded() {
        guard shouldAdvertise, transmit == nil else { return }
        typealias Init = @convention(c) (AnyObject, Selector, CBUUID, Bool) -> Unmanaged<NSObject>
        let allocated = make("CBMutableService")
        let selector = NSSelectorFromString("initWithType:primary:")
        let function = unsafeBitCast(allocated.method(for: selector), to: Init.self)
        let service = function(allocated, selector, Self.serviceUUID, true).takeUnretainedValue()
        // write 0x08, writeWithoutResponse 0x04, notify 0x10, read 0x02; readable 1, writeable 2.
        let receive = characteristic(Self.receiveUUID, properties: 0x08 | 0x04, permissions: 2)
        let transmit = characteristic(Self.transmitUUID, properties: 0x10 | 0x02, permissions: 1)
        service.setValue([receive, transmit], forKey: "characteristics")
        self.transmit = transmit
        manager?.perform(NSSelectorFromString("addService:"), with: service)
    }

    private func drain() {
        guard let manager, let transmit, let central = subscribedCentral else { return }
        typealias Update = @convention(c) (AnyObject, Selector, NSData, AnyObject, NSArray?) -> Bool
        let selector = NSSelectorFromString("updateValue:forCharacteristic:onSubscribedCentrals:")
        let function = unsafeBitCast(manager.method(for: selector), to: Update.self)
        while let packet = pendingPackets.first {
            guard function(manager, selector, packet as NSData, transmit, [central] as NSArray) else { return }
            pendingPackets.removeFirst()
            sentPacketCount += 1
        }
        let ready = drainWaiters.prefix { $0.target <= sentPacketCount }
        drainWaiters.removeFirst(ready.count)
        ready.forEach { $0.completion() }
    }

    private func respond(_ request: NSObject, _ result: Int) {
        guard let manager else { return }
        typealias Respond = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
        let selector = NSSelectorFromString("respondToRequest:withResult:")
        unsafeBitCast(manager.method(for: selector), to: Respond.self)(manager, selector, request, result)
    }

    @objc(peripheralManagerDidUpdateState:) func didUpdateState(_ peripheral: NSObject) {
        let names = [0: "unknown", 1: "resetting", 2: "unsupported", 3: "unauthorized", 4: "powered off", 5: "powered on"]
        let raw = (peripheral.value(forKey: "state") as? NSNumber)?.intValue ?? 0
        delegate?.musePeripheral(self, didChange: .bluetoothState(names[raw] ?? "unknown"))
        if raw == 5 { publishServiceIfNeeded() }
    }

    @objc(peripheralManager:didAddService:error:) func didAdd(_ peripheral: NSObject, service: AnyObject, error: NSError?) {
        if let error {
            delegate?.musePeripheral(self, didChange: .error("Could not publish GATT service: \(error.localizedDescription)"))
            return
        }
        guard shouldAdvertise else { return }
        let advert: [String: Any] = [CBAdvertisementDataLocalNameKey: localName, CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]]
        peripheral.perform(NSSelectorFromString("startAdvertising:"), with: advert)
    }

    @objc(peripheralManagerDidStartAdvertising:error:) func didStart(_ peripheral: NSObject, error: NSError?) {
        if let error {
            delegate?.musePeripheral(self, didChange: .error("Advertising failed: \(error.localizedDescription)"))
        } else {
            delegate?.musePeripheral(self, didChange: .advertising)
        }
    }

    @objc(peripheralManager:central:didSubscribeToCharacteristic:) func didSubscribe(_ peripheral: NSObject, central: NSObject, characteristic: AnyObject) {
        if let existing = identifier(subscribedCentral), existing != identifier(central) {
            delegate?.musePeripheral(self, didChange: .error("A second central was rejected"))
            return
        }
        subscribedCentral = central
        let maximum = (central.value(forKey: "maximumUpdateValueLength") as? NSNumber)?.intValue ?? 20
        transportMTU = min(maximum, BLEFraming.maxPacketBytes) + 3
        delegate?.musePeripheral(self, didChange: .subscribed(mtu: transportMTU))
        drain()
    }

    @objc(peripheralManager:central:didUnsubscribeFromCharacteristic:) func didUnsubscribe(_ peripheral: NSObject, central: NSObject, characteristic: AnyObject) {
        guard identifier(subscribedCentral) == identifier(central) else { return }
        subscribedCentral = nil
        pendingPackets.removeAll()
        drainWaiters.removeAll()
        delegate?.musePeripheral(self, didChange: .disconnected)
    }

    @objc(peripheralManager:didReceiveWriteRequests:) func didReceiveWrites(_ peripheral: NSObject, requests: [NSObject]) {
        for request in requests {
            let central = request.value(forKey: "central") as? NSObject
            if let existing = identifier(subscribedCentral), existing != identifier(central) {
                respond(request, 8)
                continue
            }
            let target = (request.value(forKey: "characteristic") as? NSObject)?.value(forKey: "UUID") as? CBUUID
            guard target == Self.receiveUUID, let value = request.value(forKey: "value") as? Data else {
                respond(request, 6)
                continue
            }
            subscribedCentral = central
            delegate?.musePeripheral(self, didReceive: value)
            respond(request, 0)
        }
    }

    @objc(peripheralManager:didReceiveReadRequest:) func didReceiveRead(_ peripheral: NSObject, request: NSObject) {
        guard (request.value(forKey: "offset") as? NSNumber)?.intValue == 0 else {
            respond(request, 7)
            return
        }
        request.setValue(Data(), forKey: "value")
        respond(request, 0)
    }

    @objc(peripheralManagerIsReadyToUpdateSubscribers:) func isReady(_ peripheral: NSObject) {
        drain()
    }
}
