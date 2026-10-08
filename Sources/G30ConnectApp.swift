import SwiftUI
import CoreBluetooth
import Combine

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

// CoreBluetooth and pairing callbacks run on the main queue.
final class BluetoothModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let pairing = PairingTest()
    private var pairingObservation: AnyCancellable?
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
    @Published var queryStatus = "Noch keine aktive Abfrage durchgeführt."
    private var writeCharacteristic: CBCharacteristic?
    private var queryPending = false
    private var querySent = false
    private var queryTimeout: DispatchWorkItem?
    private var replyBuffer: [UInt8] = []
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
        pairingObservation = pairing.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
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
        record("G30 Connect 0.7 · Fahrmodus mit Rückleseprüfung")
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
        if service.uuid == uartService {
            writeCharacteristic = service.characteristics?.first {
                $0.uuid == CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") && $0.properties.contains(.write)
            }
        }
    }

    private func resetReceiver() {
        pairing.reset()
        queryTimeout?.cancel()
        queryPending = false
        querySent = false
        writeCharacteristic = nil
        replyBuffer = []
        queryStatus = "Noch keine aktive Abfrage durchgeführt."
        receiveTimeout?.cancel()
        receiveCharacteristic = nil
        receiveStarted = nil
        receiverReady = false
        receiving = false
        packetCount = 0
        receiveStatus = "Empfang wird nach dem Verbinden verfügbar."
    }

    func startReceiveTest() {
        guard !queryPending, !pairing.active else { return }
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
        if queryPending {
            queryTimeout?.cancel()
            queryPending = false
            queryStatus = "Leseabfrage beendet."
        }
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
        if pairing.active {
            if characteristic.isNotifying || error != nil { pairing.subscribed(error: error) }
            return
        }
        if let error = error {
            queryTimeout?.cancel()
            queryPending = false
            queryStatus = "Empfangsaktivierung fehlgeschlagen. Keine Abfrage gesendet."
            receiveTimeout?.cancel()
            receiving = false
            receiveStatus = "Empfang konnte nicht aktiviert oder deaktiviert werden."
            record("Benachrichtigungsfehler: \(error.localizedDescription)")
        } else if receiving && characteristic.isNotifying {
            receiveStatus = "Empfang aktiv · warte auf Daten vom Scooter …"
            record("UART-Benachrichtigungen bestätigt.")
            if queryPending { sendVersionQuery() }
        } else if !receiving && characteristic.isNotifying {
            // Handle a late successful enable after the test was cancelled.
            peripheral.setNotifyValue(false, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if selected === peripheral, characteristic === receiveCharacteristic, pairing.active {
            if let data = characteristic.value, error == nil { pairing.received(data) }
            return
        }
        guard selected === peripheral, characteristic === receiveCharacteristic, receiving else { return }
        if let error = error { record("Empfangsfehler: \(error.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        packetCount += 1
        receiveStatus = "Empfang aktiv · \(packetCount) Datenpakete"
        let seconds = Date().timeIntervalSince(receiveStarted ?? Date())
        if queryPending { parseQueryReply(data) }
        // Cap logging to avoid flooding the UI and bound each packet's export size.
        if packetCount <= 40 {
            let hex = data.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " ")
            record(String(format: "RX +%.3fs", seconds) + " · \(data.count) Bytes: " + hex + (data.count > 128 ? " … (gekürzt)" : ""))
        } else if packetCount == 41 {
            record("Weitere Pakete werden nur gezählt; die ersten 40 sind im Bericht.")
        }
    }

    var canQuery: Bool { connected && receiverReady && writeCharacteristic != nil && !receiving && !queryPending && !pairing.active }

    func startPairing() {
        guard canQuery, let peripheral = selected, let tx = receiveCharacteristic, let rx = writeCharacteristic else { return }
        pairing.start(peripheral: peripheral, tx: tx, rx: rx, name: deviceName) { [weak self] message in self?.record(message) }
    }

    func startVersionQuery() {
        guard canQuery, let peripheral = selected, let tx = receiveCharacteristic else { return }
        queryPending = true
        querySent = false
        replyBuffer = []
        receiving = true
        packetCount = 0
        receiveStarted = Date()
        queryStatus = "Aktiviere Empfang für eine einzelne Leseabfrage …"
        receiveStatus = "Aktive Leseabfrage läuft …"
        record("Legacy-Test: CMD 01 (Lesen), Controller 20, Register 1A, Länge 2. XiaoDash-Unterstützung ungeprüft.")
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.queryPending else { return }
            self.queryPending = false
            self.queryStatus = self.querySent
                ? "Keine passende Legacy-Antwort. Verschlüsselung, Authentifizierung oder anderes Protokoll möglich."
                : "Empfang nicht rechtzeitig bestätigt; keine Anfrage gesendet."
            self.record(self.queryStatus)
            self.stopReceiveTest()
        }
        queryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        if tx.isNotifying { sendVersionQuery() }
        else { peripheral.setNotifyValue(true, for: tx) }
    }

    private func sendVersionQuery() {
        guard queryPending, !querySent, let peripheral = selected,
              let rx = writeCharacteristic, receiveCharacteristic?.isNotifying == true else { return }
        // Ninebot ES protocol: one read of the read-only firmware version register.
        // Source 3E = phone, destination 20 = ESC, command 01 = read, payload 02 = two bytes.
        // No retries, writes to configuration registers, or pairing changes.
        let packet: [UInt8] = [0x5A, 0xA5, 0x01, 0x3E, 0x20, 0x01, 0x1A, 0x02, 0x83, 0xFF]
        querySent = true
        queryStatus = "Eine Versionsabfrage gesendet · warte auf Antwort …"
        record("TX: 5A A5 01 3E 20 01 1A 02 83 FF (nur Versionsabfrage)")
        peripheral.writeValue(Data(packet), for: rx, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if selected === peripheral, characteristic === writeCharacteristic, pairing.active {
            pairing.wrote(error: error)
            return
        }
        guard selected === peripheral, characteristic === writeCharacteristic, queryPending else { return }
        if let error = error {
            queryPending = false
            queryTimeout?.cancel()
            queryStatus = "Anfrage konnte nicht übertragen werden: \(error.localizedDescription)"
            record(queryStatus)
            stopReceiveTest()
        } else {
            record("Bluetooth bestätigt Übertragung. Dies bestätigt noch keine Protokoll-Antwort.")
        }
    }

    private func parseQueryReply(_ data: Data) {
        replyBuffer.append(contentsOf: data)
        if replyBuffer.count > 1024 { replyBuffer = Array(replyBuffer.suffix(512)) }
        while replyBuffer.count >= 3 {
            guard replyBuffer[0] == 0x5A, replyBuffer[1] == 0xA5 else {
                replyBuffer.removeFirst()
                continue
            }
            let count = Int(replyBuffer[2]) + 9
            guard replyBuffer.count >= count else { return }
            let frame = Array(replyBuffer.prefix(count))
            let sum = frame[2..<(count - 2)].reduce(UInt16(0)) { $0 &+ UInt16($1) }
            let crc = UInt16(frame[count - 2]) | (UInt16(frame[count - 1]) << 8)
            guard crc == ~sum else { replyBuffer.removeFirst(); continue }
            replyBuffer.removeFirst(count)
            guard querySent, frame[2] == 2, frame[3] == 0x20, frame[4] == 0x3E,
                  frame[5] == 0x04, frame[6] == 0x1A else { continue }
            let version = UInt16(frame[7]) | (UInt16(frame[8]) << 8)
            queryPending = false
            queryTimeout?.cancel()
            queryStatus = String(format: "Gültige Legacy-Antwort · Versionsregister: 0x%04X.", version)
            record(queryStatus)
            record("Der Registerwert kann durch XiaoDash überschrieben sein; er identifiziert nicht zuverlässig die echte Firmware-Version.")
            stopReceiveTest()
            return
        }
    }

    var report: String { log.joined(separator: "\n") + "\n\n" + pairing.report }
}

struct ContentView: View {
    @ObservedObject var model: BluetoothModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("G30 CONNECT", systemImage: "scooter")
                        .font(.title2.bold()).foregroundStyle(.mint)
                    Text("Dein Scooter. Deine Verbindung.").font(.headline)
                    Text("Version 0.7 · Messwerte und Fahrmodus").foregroundStyle(.secondary)
                    Text(model.status).accessibilityIdentifier("connectionStatus")
                    if model.scanning || model.busy { ProgressView() }
                    Button(model.scanning ? "Erneut suchen" : "Scooter suchen") { model.scan() }
                        .buttonStyle(.borderedProminent).tint(.mint)
                        .disabled(!model.ready || model.busy || model.connected)
                    if model.connected || model.busy {
                        Button("Verbindung trennen", role: .destructive) { model.disconnect() }
                    }
                }
                Section("Anmeldung und Messwerte") {
                    Text(model.pairing.status).font(.headline)
                    if model.pairing.authenticated {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ForEach([UInt8(0x22), 0x26, 0x3E, 0x47], id: \.self) { register in
                                let reading = model.pairing.readings[register]
                                let titles: [UInt8: String] = [0x22: "Akku", 0x26: "Geschwindigkeit", 0x3E: "Controller-Temperatur", 0x47: "Spannung"]
                                HStack {
                                    Text(titles[register] ?? "Messwert")
                                    Spacer()
                                    if let reading = reading, context.date.timeIntervalSince(reading.timestamp) <= 10 {
                                        Text(reading.text).monospacedDigit().foregroundStyle(.mint)
                                    } else { Text("—").foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if let version = model.pairing.version {
                            Text("Versionsregister: \(version) · kann überschrieben sein").font(.caption)
                        }
                        Text("Messwerte aus Standardregistern. Bitte Akku, Temperatur und Spannung beim ersten Test im Stand mit XiaoDash vergleichen. Werte ohne aktuelle Antwort erscheinen als —.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Drücke die Ein-/Lichttaste einmal kurz, sobald die App dich dazu auffordert. Danach liest sie die Messwerte automatisch.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.pairing.active {
                        if !model.pairing.authenticated { ProgressView() }
                        Button("Datenabfrage beenden") { model.pairing.cancel() }
                    } else {
                        Button("Anmelden und Daten lesen") { model.startPairing() }
                            .buttonStyle(.borderedProminent).tint(.mint)
                            .disabled(!model.canQuery)
                    }
                }
                Section("Fahrmodus") {
                    Text("Aktuell: \(model.pairing.rideMode?.title ?? "wird gelesen …")").font(.headline)
                    Text(model.pairing.modeChangeStatus)
                    HStack {
                        ForEach([RideMode.eco, .normal, .sport]) { mode in
                            Button(mode.title) { model.pairing.changeMode(mode) }
                                .buttonStyle(.bordered)
                                .disabled(!model.pairing.canChangeMode || scenePhase != .active)
                        }
                    }
                    if model.pairing.modeChangeBusy { ProgressView() }
                    Text("Modus im Stand wählen. Die App prüft die Geschwindigkeit erneut und zeigt eine Änderung erst nach dem Zurücklesen an. Geschwindigkeitsgrenzen und Motorströme werden dabei nicht eingestellt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Einstellungen prüfen") {
                    Text(model.pairing.configurationStatus)
                    Text("Liest elf dokumentierte Einstellungsregister aus den ES- und G30-Tabellen. Die Zuordnung zu XiaoDash wird anhand der Antworten geprüft; Fahrparameter werden noch nicht verändert.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Einstellungen auslesen") { model.pairing.inspectConfiguration() }
                        .disabled(!model.pairing.authenticated || model.pairing.inspectingConfiguration || model.pairing.modeChangeBusy)
                    if model.pairing.inspectingConfiguration {
                        ProgressView(value: Double(model.pairing.configurationCompleted), total: Double(PairingTest.configurationRegisters.count))
                        Text("Bei fehlenden Antworten kann die Prüfung etwa eine Minute dauern.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.pairing.configurationValues.keys.sorted(), id: \.self) { register in
                        Text(String(format: "Register 0x%02X: 0x%04X", register, model.pairing.configurationValues[register] ?? 0))
                            .font(.caption.monospaced())
                    }
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
                    Text("Teile den Bericht hier im Chat, damit wir die nächste Version anpassen können. Der Bericht enthält Anmeldestatus und Messwerte; keine Schlüssel oder Anmelde-Rohpakete.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: model.report) { Label("Bericht teilen", systemImage: "square.and.arrow.up") }
                        .disabled(model.log.isEmpty)
                    Text(model.report).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("G30 Connect")
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { phase in
                // Do not complete a queued control operation after the user leaves the app.
                if phase == .background && model.pairing.modeChangeBusy { model.disconnect() }
            }
        }
    }
}



