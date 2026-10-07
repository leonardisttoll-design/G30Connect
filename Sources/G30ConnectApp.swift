import SwiftUI
import CoreBluetooth

@main
struct G30ConnectApp: App {
    @StateObject private var bluetooth = BluetoothModel()
    var body: some Scene {
        WindowGroup { ContentView(model: bluetooth) }
    }
}

struct NearbyDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

struct ServiceInfo: Identifiable {
    let id = UUID()
    let uuid: String
    var characteristics: [String]
}

// All CoreBluetooth callbacks run on the main queue. No scooter commands are sent.
final class BluetoothModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Bluetooth wird vorbereitet …"
    @Published var ready = false
    @Published var scanning = false
    @Published var busy = false
    @Published var connected = false
    @Published var deviceName = "Kein Scooter verbunden"
    @Published var devices: [NearbyDevice] = []
    @Published var services: [ServiceInfo] = []
    @Published var log: [String] = []
    @Published var receiverReady = false
    @Published var receiving = false
    @Published var packetCount = 0
    @Published var receiveStatus = "Empfang wird nach dem Verbinden verfügbar."
    private let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private var receiveCharacteristic: CBCharacteristic?
    private var receiveTimeout: DispatchWorkItem?
    private var receiveStarted: Date?
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?
    private var scanTimeout: DispatchWorkItem?
    private var connectionTimeout: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func record(_ message: String) {
        log.append(message)
        if log.count > 150 { log.removeFirst(log.count - 150) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        ready = central.state == .poweredOn
        switch central.state {
        case .poweredOn: status = "Bereit zur Suche"
        case .poweredOff: status = "Bitte Bluetooth in den iPhone-Einstellungen einschalten."
        case .unauthorized: status = "Bitte Bluetooth-Zugriff in den iPhone-Einstellungen erlauben."
        case .unsupported: status = "Dieses Gerät unterstützt Bluetooth LE nicht."
        case .resetting: status = "Bluetooth startet neu …"
        default: status = "Bluetooth wird vorbereitet …"
        }
        if !ready {
            resetReceiver()
            scanTimeout?.cancel()
            connectionTimeout?.cancel()
            scanning = false
            busy = false
            connected = false
            selected = nil
            services = []
            devices = []
            peripherals = [:]
            deviceName = "Kein Scooter verbunden"
        }
        record(status)
    }

    func scan() {
        guard ready, !busy, !connected else { return }
        stopScan()
        devices = []
        peripherals = [:]
        services = []
        log = []
        scanning = true
        status = "Suche läuft für 15 Sekunden …"
        record("G30 Connect 0.2 · UART-Empfangstest ohne Scooter-Schreibbefehle")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stopScan()
            self.status = self.devices.isEmpty
                ? "Kein Gerät gefunden. Scooter einschalten und andere Scooter-Apps schließen."
                : "Wähle deinen Scooter aus der Liste."
        }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func stopScan() {
        scanTimeout?.cancel()
        central.stopScan()
        scanning = false
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unbenanntes Bluetooth-Gerät"
        peripherals[peripheral.identifier] = peripheral
        let device = NearbyDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else { devices.append(device) }
        devices.sort { $0.rssi > $1.rssi }
    }

    func connect(_ device: NearbyDevice) {
        guard ready, !busy, !connected, let peripheral = peripherals[device.id] else { return }
        stopScan()
        services = []
        resetReceiver()
        selected = peripheral
        peripheral.delegate = self
        deviceName = device.name
        busy = true
        status = "Verbinde mit \(device.name) …"
        record("Verbindungsversuch mit ausgewähltem Gerät (Name und Geräte-ID nicht im Export).")
        central.connect(peripheral, options: nil)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.busy, self.selected === peripheral else { return }
            self.selected = nil
            self.busy = false
            self.deviceName = "Kein Scooter verbunden"
            self.central.cancelPeripheralConnection(peripheral)
            self.status = "Verbindung nach 15 Sekunden abgebrochen. Andere Scooter-Apps schließen und erneut versuchen."
            self.record("Verbindungs-Timeout")
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func disconnect() {
        stopReceiveTest()
        resetReceiver()
        connectionTimeout?.cancel()
        stopScan()
        if let peripheral = selected { central.cancelPeripheralConnection(peripheral) }
        selected = nil
        busy = false
        connected = false
        deviceName = "Kein Scooter verbunden"
        status = "Verbindung getrennt"
        record(status)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard selected === peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectionTimeout?.cancel()
        busy = false
        connected = true
        status = "Verbunden · Dienste werden gesucht …"
        record("Bluetooth-Verbindung hergestellt. XiaoDash-Kompatibilität noch ungeprüft.")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard selected === peripheral else { return }
        resetReceiver()
        connectionTimeout?.cancel()
        selected = nil
        busy = false
        connected = false
        deviceName = "Kein Scooter verbunden"
        status = "Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "Unbekannter Fehler")"
        record(status)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard selected === peripheral else { return }
        resetReceiver()
        connectionTimeout?.cancel()
        selected = nil
        busy = false
        connected = false
        deviceName = "Kein Scooter verbunden"
        status = "Verbindung getrennt"
        record(error.map { "Verbindungsabbruch: \($0.localizedDescription)" } ?? status)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected === peripheral else { return }
        if let error = error {
            status = "Dienste konnten nicht gelesen werden."
            record(error.localizedDescription)
            return
        }
        let discovered = peripheral.services ?? []
        services = discovered.map { ServiceInfo(uuid: $0.uuid.uuidString, characteristics: []) }
        status = "Verbunden · \(discovered.count) Dienste gefunden"
        for service in discovered {
            record("Dienst: \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected === peripheral else { return }
        if let error = error { record("Dienstfehler: \(error.localizedDescription)"); return }
        let descriptions = (service.characteristics ?? []).map { characteristic -> String in
            let p = characteristic.properties
            var flags: [String] = []
            if p.contains(.read) { flags.append("Lesen") }
            if p.contains(.write) { flags.append("Schreiben") }
            if p.contains(.writeWithoutResponse) { flags.append("Schreiben ohne Antwort") }
            if p.contains(.notify) { flags.append("Benachrichtigungen") }
            if p.contains(.indicate) { flags.append("Bestätigte Benachrichtigungen") }
            return "\(characteristic.uuid.uuidString) · \(flags.joined(separator: ", "))"
        }
        // Match by object position to preserve services with repeated UUIDs.
        if let index = peripheral.services?.firstIndex(where: { $0 === service }), services.indices.contains(index) {
            services[index].characteristics = descriptions
        }
        descriptions.forEach { record("\(service.uuid.uuidString) / \($0)") }
        if service.uuid == uartService,
           let tx = service.characteristics?.first(where: { $0.uuid == uartTX && $0.properties.contains(.notify) }) {
            receiveCharacteristic = tx
            receiverReady = true
            receiveStatus = "Empfangsschnittstelle gefunden. Starte den 20-Sekunden-Test."
        }
    }

    private func resetReceiver() {
        receiveTimeout?.cancel()
        receiveCharacteristic = nil
        receiveStarted = nil
        receiverReady = false
        receiving = false
        packetCount = 0
        receiveStatus = "Empfang wird nach dem Verbinden verfügbar."
    }

    func startReceiveTest() {
        guard connected, !receiving, let peripheral = selected,
              let characteristic = receiveCharacteristic else { return }
        receiveTimeout?.cancel()
        packetCount = 0
        receiving = true
        receiveStarted = Date()
        receiveStatus = "Benachrichtigungen werden aktiviert …"
        record("UART-Empfangstest gestartet (20 Sekunden). Rohdaten können Geräteinformationen enthalten.")
        peripheral.setNotifyValue(true, for: characteristic)
        let timeout = DispatchWorkItem { [weak self] in self?.stopReceiveTest() }
        receiveTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func stopReceiveTest() {
        receiveTimeout?.cancel()
        guard receiving else { return }
        receiving = false
        if let peripheral = selected, let characteristic = receiveCharacteristic {
            peripheral.setNotifyValue(false, for: characteristic)
        }
        receiveStatus = packetCount == 0
            ? "Keine Daten empfangen. Möglicherweise sind erst Authentifizierung oder Abfragen nötig."
            : "Test beendet · \(packetCount) Datenpakete empfangen."
        record(receiveStatus)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral, characteristic === receiveCharacteristic else { return }
        if let error = error {
            receiveTimeout?.cancel()
            receiving = false
            receiveStatus = "Empfang konnte nicht aktiviert oder deaktiviert werden."
            record("Benachrichtigungsfehler: \(error.localizedDescription)")
        } else if receiving && characteristic.isNotifying {
            receiveStatus = "Empfang aktiv · warte auf Daten vom Scooter …"
            record("UART-Benachrichtigungen bestätigt.")
        } else if !receiving && characteristic.isNotifying {
            // Handle a late successful enable after the test was cancelled.
            peripheral.setNotifyValue(false, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral, characteristic === receiveCharacteristic, receiving else { return }
        if let error = error { record("Empfangsfehler: \(error.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        packetCount += 1
        receiveStatus = "Empfang aktiv · \(packetCount) Datenpakete"
        let seconds = Date().timeIntervalSince(receiveStarted ?? Date())
        // Cap logging to avoid flooding the UI and bound each packet's export size.
        if packetCount <= 40 {
            let hex = data.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " ")
            record(String(format: "RX +%.3fs", seconds) + " · \(data.count) Bytes: " + hex + (data.count > 128 ? " … (gekürzt)" : ""))
        } else if packetCount == 41 {
            record("Weitere Pakete werden nur gezählt; die ersten 40 sind im Bericht.")
        }
    }

    var report: String { log.joined(separator: "\n") }
}

struct ContentView: View {
    @ObservedObject var model: BluetoothModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("G30 CONNECT", systemImage: "scooter")
                        .font(.title2.bold()).foregroundStyle(.mint)
                    Text("Dein Scooter. Deine Verbindung.").font(.headline)
                    Text("Version 0.2 · Datenempfangstest").foregroundStyle(.secondary)
                    Text(model.status).accessibilityIdentifier("connectionStatus")
                    if model.scanning || model.busy { ProgressView() }
                    Button(model.scanning ? "Erneut suchen" : "Scooter suchen") { model.scan() }
                        .buttonStyle(.borderedProminent).tint(.mint)
                        .disabled(!model.ready || model.busy || model.connected)
                    if model.connected || model.busy {
                        Button("Verbindung trennen", role: .destructive) { model.disconnect() }
                    }
                }
                Section("Datenempfang") {
                    Text(model.receiveStatus)
                    Text("Der Test aktiviert für 20 Sekunden den Empfang von Bluetooth-Benachrichtigungen. Er prüft, ob der Scooter von selbst Daten sendet. Geschwindigkeit und Akkustand werden noch nicht entschlüsselt.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.receiving {
                        Button("Empfangstest beenden") { model.stopReceiveTest() }
                    } else {
                        Button("Datenempfang testen (20 Sekunden)") { model.startReceiveTest() }
                            .disabled(!model.connected || !model.receiverReady)
                    }
                    Text("Empfangene Pakete: \(model.packetCount)").font(.caption)
                }
                Section("Bluetooth-Geräte") {
                    if model.devices.isEmpty {
                        Text("Schalte den Scooter ein und schließe XiaoDash auf dem anderen Handy. Tippe dann auf ‚Scooter suchen‘.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { device in
                        Button { model.connect(device) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text("Signal: \(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                        }.disabled(model.busy || model.connected)
                    }
                }
                Section(model.connected ? model.deviceName : "Letztes Diagnoseergebnis") {
                    Text("Eine Bluetooth-Verbindung bestätigt noch keine XiaoDash-Unterstützung. Diese Version verändert keine Scooter-Einstellungen.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(model.services) { service in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(service.uuid).font(.caption.monospaced().bold())
                            ForEach(Array(service.characteristics.enumerated()), id: \.offset) { _, value in
                                Text(value).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("Diagnose teilen") {
                    Text("Teile den Bericht hier im Chat, damit wir die nächste Version anpassen können. Empfangene Rohdaten können Geräteinformationen enthalten. Prüfe den Text vor dem Teilen und lade ihn nicht ins öffentliche GitHub-Repository.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: model.report) { Label("Bericht teilen", systemImage: "square.and.arrow.up") }
                        .disabled(model.log.isEmpty)
                    Text(model.report).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("G30 Connect")
            .preferredColorScheme(.dark)
        }
    }
}
