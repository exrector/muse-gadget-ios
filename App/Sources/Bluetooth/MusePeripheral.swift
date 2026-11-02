import CoreBluetooth
import Foundation

protocol MusePeripheralDelegate: AnyObject {
    func musePeripheral(_ peripheral: MusePeripheral, didChange event: MusePeripheral.Event)
    func musePeripheral(_ peripheral: MusePeripheral, didReceive packet: Data)
}

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
    private var manager: CBPeripheralManager!
    private var transmit: CBMutableCharacteristic?
    private var subscribedCentral: CBCentral?
    private var pendingPackets: [Data] = []
    private var shouldAdvertise = false

    private(set) var transportMTU = 23

    init(localName: String) {
        self.localName = localName
        super.init()
    }

    func start() {
        shouldAdvertise = true
        if manager == nil {
            manager = CBPeripheralManager(
                delegate: self,
                queue: .main,
                options: [CBPeripheralManagerOptionRestoreIdentifierKey: "MuseGadgetLegacy.peripheral"]
            )
        } else if manager.state == .poweredOn {
            publishServiceIfNeeded()
        }
    }

    func stop() {
        shouldAdvertise = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        transmit = nil
        subscribedCentral = nil
        pendingPackets.removeAll()
    }

    func send(_ packets: [Data]) {
        pendingPackets.append(contentsOf: packets)
        drain()
    }

    private func publishServiceIfNeeded() {
        guard shouldAdvertise, transmit == nil else { return }
        let receive = CBMutableCharacteristic(
            type: Self.receiveUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let transmit = CBMutableCharacteristic(
            type: Self.transmitUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [receive, transmit]
        self.transmit = transmit
        manager.add(service)
    }

    private func drain() {
        guard let manager, let transmit, let central = subscribedCentral else { return }
        while let packet = pendingPackets.first {
            guard manager.updateValue(packet, for: transmit, onSubscribedCentrals: [central]) else { return }
            pendingPackets.removeFirst()
        }
    }
}

extension MusePeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state: String
        switch peripheral.state {
        case .poweredOn: state = "powered on"
        case .poweredOff: state = "powered off"
        case .unauthorized: state = "unauthorized"
        case .unsupported: state = "unsupported"
        case .resetting: state = "resetting"
        case .unknown: state = "unknown"
        @unknown default: state = "unknown"
        }
        delegate?.musePeripheral(self, didChange: .bluetoothState(state))
        if peripheral.state == .poweredOn { publishServiceIfNeeded() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            delegate?.musePeripheral(self, didChange: .error("Could not publish GATT service: \(error.localizedDescription)"))
            return
        }
        guard shouldAdvertise else { return }
        // The working macOS adapter found name-only advertising more reliable:
        // the 128-bit service remains discoverable after connection.
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: localName])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            delegate?.musePeripheral(self, didChange: .error("Advertising failed: \(error.localizedDescription)"))
        } else {
            delegate?.musePeripheral(self, didChange: .advertising)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard subscribedCentral == nil || subscribedCentral?.identifier == central.identifier else {
            delegate?.musePeripheral(self, didChange: .error("A second central was rejected"))
            return
        }
        subscribedCentral = central
        transportMTU = min(central.maximumUpdateValueLength, BLEFraming.maxPacketBytes) + 3
        delegate?.musePeripheral(self, didChange: .subscribed(mtu: transportMTU))
        drain()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard subscribedCentral?.identifier == central.identifier else { return }
        subscribedCentral = nil
        pendingPackets.removeAll()
        delegate?.musePeripheral(self, didChange: .disconnected)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let existing = subscribedCentral, existing.identifier != request.central.identifier {
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
                continue
            }
            guard request.characteristic.uuid == Self.receiveUUID, let value = request.value else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            subscribedCentral = request.central
            delegate?.musePeripheral(self, didReceive: value)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.offset == 0 else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drain()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        delegate?.musePeripheral(self, didChange: .bluetoothState("restored"))
    }
}

