import CoreBluetooth
import Foundation

/// Listens to every Bluetooth LE advertisement in range (foreground only).
final class BLEScanner: NSObject, CBCentralManagerDelegate {
    var onSample: ((BLESample) -> Void)?
    var onStatus: ((String) -> Void)?

    private var central: CBCentralManager?
    private var wantScan = false

    func start() {
        wantScan = true
        if let central {
            if central.state == .poweredOn { scan() }
        } else {
            central = CBCentralManager(delegate: self, queue: nil) // main queue; triggers the permission prompt
        }
    }

    func stop() {
        wantScan = false
        central?.stopScan()
    }

    private func scan() {
        // Allow duplicates: we want every advertisement, not just the first one per device.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        onStatus?("Scanning")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScan { scan() }
        case .poweredOff: onStatus?("Bluetooth is off. Turn it on in Control Center.")
        case .unauthorized: onStatus?("Bluetooth not allowed. Settings › BLE Scout › Bluetooth.")
        case .unsupported: onStatus?("This device has no Bluetooth LE.")
        default: onStatus?("Bluetooth starting…")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard rssi < 0, rssi > -110 else { return } // 127 = "not available"
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let name = advName?.trimmingCharacters(in: .whitespacesAndNewlines)
        onSample?(BLESample(t: ProcessInfo.processInfo.systemUptime, id: peripheral.identifier.uuidString,
                            name: (name?.isEmpty ?? true) ? nil : name, rssi: rssi))
    }
}
