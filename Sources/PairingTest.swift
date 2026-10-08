// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreBluetooth
import Security
import Combine

final class PairingTest: ObservableObject {
    @Published var active = false
    @Published var authenticated = false
    @Published var readings: [UInt8: TelemetryReading] = [:]
    @Published var version: String?
    @Published var rideMode: RideMode?
    @Published var modeChangeBusy = false
    @Published var modeChangeStatus = "Fahrmodus noch nicht geändert."
    private var modeChange: ModeChangeTransaction?
    private var modeSpeedTime: Date?
    @Published var configurationStatus = "Einstellungen noch nicht ausgelesen."
    @Published var configurationValues: [UInt8: UInt16] = [:]
    @Published var inspectingConfiguration = false
    @Published var configurationCompleted = 0
    private var configurationAttempted = Set<UInt8>()
    static let configurationRegisters: [UInt8] = [0x7B, 0x7C, 0x7D, 0x7F, 0x73, 0x90, 0x72, 0x74, 0x75, 0x80, 0x81]
    private var configurationQueue: [UInt8] = []
    private var requestedConfiguration = false
    private var lastMeasurementReport = ""
    private let registers: [UInt8] = [0x22, 0x26, 0x3E, 0x47, 0x75]
    private var registerIndex = 0
    private var requestedRegister: UInt8?
    @Published var status = "Anmeldung noch nicht getestet."
    private var crypto: NinebotSessionCrypto?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var timer: DispatchWorkItem?
    private var stage = "idle"
    private var nonce: [UInt8] = []
    private var serial: [UInt8] = []
    private var buffer: [UInt8] = []
    private var chunks: [Data] = []
    private var pendingReplies: [[UInt8]] = []
    private var retries = 0
    private var deadline = Date()
    private var logger: ((String) -> Void)?

    func start(peripheral: CBPeripheral, tx: CBCharacteristic, rx: CBCharacteristic,
               name: String, log: @escaping (String) -> Void) {
        guard !active else { return }
        self.peripheral = peripheral; self.tx = tx; self.rx = rx; logger = log
        crypto = NinebotSessionCrypto(name: name)
        buffer = []; chunks = []; pendingReplies = []; serial = []; retries = 0
        authenticated = false; readings = [:]; version = nil; registerIndex = 0; requestedRegister = nil
        configurationValues = [:]; configurationQueue = []; inspectingConfiguration = false
        configurationCompleted = 0; configurationAttempted = []
        requestedConfiguration = false
        rideMode = nil; modeChange = nil; modeChangeBusy = false; modeSpeedTime = nil
        modeChangeStatus = "Fahrmodus noch nicht geändert."
        configurationStatus = "Einstellungen noch nicht ausgelesen."
        lastMeasurementReport = ""
        nonce = [UInt8](repeating: 0, count: 16)
        let randomResult = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard randomResult == errSecSuccess else { finish("Zufallsschlüssel konnte nicht erzeugt werden."); return }
        active = true
        stage = "subscribe"
        status = "Aktiviere Empfang für die verschlüsselte Anmeldung …"
        log("Anmeldung 0.7 gestartet. Keine Schlüssel, Seriennummern oder Anmelde-Rohpakete im Bericht.")
        later(8) { [weak self] in self?.finish("Keine Bestätigung des Datenempfangs.") }
        if tx.isNotifying { subscribed(error: nil) }
        else { peripheral.setNotifyValue(true, for: tx) }
    }
    func subscribed(error: Error?) {
        guard active, stage == "subscribe" else { return }
        if error != nil { finish("Empfang konnte nicht aktiviert werden."); return }
        stage = "hello"
        status = "Frage den Scooter nach dem Anmeldeprotokoll …"
        logger?("Sende verschlüsselte Anmeldeabfrage 5B an das Dashboard.")
        later(8) { [weak self] in self?.finish("Keine gültige Antwort auf die verschlüsselte Anmeldeabfrage. BLE117/XiaoDash-Kompatibilität bleibt offen.") }
        send(command: 0x5B)
    }
    private func later(_ seconds: Double, action: @escaping () -> Void) {
        timer?.cancel()
        let item = DispatchWorkItem(block: action)
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
    private func send(command: UInt8, destination: UInt8 = 0x21, argument: UInt8 = 0, payload: [UInt8] = []) {
        guard active, chunks.isEmpty, let peripheral = peripheral, let rx = rx,
              let packet = crypto?.encrypt(command: command, destination: destination, argument: argument, payload: payload) else {
            finish("Anmeldepaket konnte nicht erstellt oder übertragen werden."); return
        }
        let bytes = Array(packet)
        let size = min(20, peripheral.maximumWriteValueLength(for: .withResponse))
        guard size > 0 else { finish("Ungültige Bluetooth-Paketgröße."); return }
        chunks = stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
        peripheral.writeValue(chunks[0], for: rx, type: .withResponse)
    }
    func wrote(error: Error?) {
        guard active, !chunks.isEmpty else { return }
        guard error == nil else { finish("Bluetooth hat die Übertragung abgelehnt."); return }
        chunks.removeFirst()
        if let next = chunks.first, let peripheral = peripheral, let rx = rx {
            peripheral.writeValue(next, for: rx, type: .withResponse)
        } else {
            let replies = pendingReplies
            pendingReplies = []
            for reply in replies where active { handle(reply) }
            if active, modeChange?.phase == .awaitingWrite {
                modeChange?.transmissionCompleted()
                later(0.2) { [weak self] in self?.pollNext() }
            }
        }
    }
    func received(_ data: Data) {
        guard active else { return }
        buffer.append(contentsOf: data)
        if buffer.count > 2048 { finish("Unerwartet große Antwort; Anmeldung beendet."); return }
        while buffer.count >= 3, active {
            guard buffer[0] == 0x5A, buffer[1] == 0xA5 else { buffer.removeFirst(); continue }
            let length = Int(buffer[2]) + 13
            guard buffer.count >= length else { return }
            let frame = Array(buffer.prefix(length))
            buffer.removeFirst(length)
            guard let plain = crypto?.decrypt(frame) else {
                logger?("Antwort nicht entschlüsselbar oder Prüfsumme ungültig.")
                continue
            }
            if chunks.isEmpty { handle(plain) }
            else {
                pendingReplies.append(plain)
                if pendingReplies.count > 8 { finish("Zu viele unerwartete Anmeldeantworten.") }
            }
        }
    }
    private func handle(_ plain: [UInt8]) {
        guard plain.count >= 7 else { return }
        let command = plain[5]
        if stage == "telemetry", modeChangeBusy, plain[3] == 0x20, command == 5,
           modeChange?.phase == .awaitingWrite || modeChange?.phase == .verify {
            logger?(String(format: "Schreibantwort CMD 05: Index 0x%02X, Datenlänge %u. Ergebnis erst nach Rücklesen bestätigt.", plain[6], plain[2]))
            return
        }
        if stage == "hello", plain[3] == 0x21, command == 0x5B, plain[2] == 30, plain.count == 37 {
            serial = Array(plain[23..<37])
            guard serial.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
                finish("Anmeldeantwort enthält kein gültiges Gerätekennzeichen."); return
            }
            logger?("Gültige verschlüsselte 5B-Antwort erhalten; Anmeldeprotokoll erkannt.")
            stage = "button"
            deadline = Date().addingTimeInterval(30)
            status = "Jetzt die Ein-/Lichttaste am Scooter EINMAL KURZ drücken. Nicht gedrückt halten."
            buttonTick()
        } else if stage == "button", plain[3] == 0x21, command == 0x5C, plain[2] == 0, plain[6] == 1 {
            logger?("Scooter bestätigt Tastendruck (5C01).")
            stage = "auth"
            deadline = Date().addingTimeInterval(10)
            retries = 0
            status = "Tastendruck bestätigt · Anmeldung wird abgeschlossen …"
            authTick()
        } else if stage == "auth", plain[3] == 0x21, command == 0x5D, plain[2] == 0, plain[6] == 1 {
            logger?("Anmeldung vom Scooter bestätigt (5D01).")
            stage = "version"
            status = "Angemeldet · frage das Versionsregister ab …"
            later(10) { [weak self] in self?.finish("Anmeldung bestätigt, aber keine passende Antwort auf die Versionsabfrage.") }
            send(command: 1, destination: 0x20, argument: 0x1A, payload: [2])
        } else if stage == "version", plain[3] == 0x20, command == 4, plain[6] == 0x1A, plain[2] == 2, plain.count == 9 {
            let value = UInt16(plain[7]) | UInt16(plain[8]) << 8
            version = String(format: "0x%04X", value)
            logger?("Anmeldung und verschlüsselte Versionsabfrage erfolgreich · \(version!) (Override möglich).")
            authenticated = true
            stage = "telemetry"
            nonce = []; serial = []
            status = "Angemeldet · lese Messwerte …"
            pollNext()
        } else if stage == "telemetry", plain[3] == 0x20, command == 4,
                  plain[6] == requestedRegister, plain[2] == 2, plain.count == 9 {
            let register = plain[6]
            requestedRegister = nil
            let rawValue = UInt16(plain[7]) | UInt16(plain[8]) << 8
            if modeChangeBusy, modeChange?.readRegister == register {
                if register == 0x26 { modeSpeedTime = Date() }
                if register == 0x75 { rideMode = RideMode(rawValue: rawValue) }
                modeChange?.accept(register: register, value: rawValue)
                later(0.2) { [weak self] in self?.pollNext() }
                return
            }
            if requestedConfiguration {
                configurationCompleted += 1
                let value = UInt16(plain[7]) | UInt16(plain[8]) << 8
                configurationValues[register] = value
                logger?(String(format: "Einstellungs-Leseprüfung: Register 0x%02X = 0x%04X (%u); XiaoDash-Bedeutung noch ungeprüft.", register, value, value))
            } else if register == 0x75 {
                rideMode = RideMode(rawValue: rawValue)
            } else if let reading = TelemetryReading.decode(register: register, low: plain[7], high: plain[8]) {
                if readings[register] == nil { logger?("Messwert \(reading.title): \(reading.text) · Standardregister, Zuordnung mit XiaoDash vergleichen.") }
                readings[register] = reading
                status = "Angemeldet · Messwerte werden aktualisiert"
            } else {
                readings.removeValue(forKey: register)
                logger?(String(format: "Register 0x%02X: unplausibler Wert 0x%02X%02X; nicht angezeigt.", register, plain[8], plain[7]))
            }
            later(0.5) { [weak self] in self?.pollNext() }
        }
    }
    func inspectConfiguration() {
        guard authenticated, active, !inspectingConfiguration, !modeChangeBusy else { return }
        configurationValues = [:]
        configurationCompleted = 0; configurationAttempted = []
        // Only documented configuration addresses; do not read identity/key registers.
        configurationQueue = Self.configurationRegisters
        inspectingConfiguration = true
        configurationStatus = "Dokumentierte Einstellungen werden gelesen …"
        logger?("Einstellungsprüfung gestartet: nur CMD 01, elf dokumentierte Standardregister (ES/G30; XiaoDash-Zuordnung ungeprüft). Keine Änderungen.")
    }
    private func pollNext() {
        guard active, stage == "telemetry", requestedRegister == nil else { return }
        if !chunks.isEmpty {
            later(0.2) { [weak self] in self?.pollNext() }
            return
        }
        if modeChangeBusy { advanceModeChange(); return }
        if inspectingConfiguration, configurationQueue.isEmpty {
            inspectingConfiguration = false
            configurationStatus = "Leseprüfung beendet · \(configurationValues.count) von \(Self.configurationRegisters.count) Antworten. XiaoDash-Zuordnung ungeprüft."
            logger?(configurationStatus)
        }
        // Alternate settings reads with live measurements to keep the display current.
        let readConfiguration = inspectingConfiguration && !requestedConfiguration
        let register: UInt8
        if readConfiguration {
            register = configurationQueue.removeFirst()
            configurationAttempted.insert(register)
            configurationStatus = "Leseprüfung \(configurationCompleted + 1)/\(Self.configurationRegisters.count) · bitte App geöffnet lassen"
        }
        else {
            register = registers[registerIndex]
            registerIndex = (registerIndex + 1) % registers.count
        }
        requestedConfiguration = readConfiguration
        requestedRegister = register
        later(5) { [weak self] in
            guard let self = self, self.active, self.stage == "telemetry", self.requestedRegister == register else { return }
            // A missing write acknowledgement must not leave the sender retrying forever.
            if !self.chunks.isEmpty { self.finish("Bluetooth-Übertragung ohne Bestätigung; bitte neu verbinden."); return }
            self.requestedRegister = nil
            if self.requestedConfiguration { self.configurationCompleted += 1 }
            else if register == 0x75 { self.rideMode = nil }
            else { self.readings.removeValue(forKey: register) }
            self.status = String(format: "Keine Antwort für Register 0x%02X · weitere Messwerte werden geprüft", register)
            self.logger?(self.status)
            self.later(0.5) { [weak self] in self?.pollNext() }
        }
        send(command: 1, destination: 0x20, argument: register, payload: [2])
    }
    var canChangeMode: Bool {
        guard authenticated, active, !inspectingConfiguration, !modeChangeBusy,
              let speed = readings[0x26] else { return false }
        return abs(speed.value) <= 0.1 && Date().timeIntervalSince(speed.timestamp) < 5
    }
    func changeMode(_ mode: RideMode) {
        guard canChangeMode else { return }
        modeChange = ModeChangeTransaction(target: mode)
        modeSpeedTime = nil
        modeChangeBusy = true
        modeChangeStatus = "Prüfe Stillstand und bisherigen Fahrmodus …"
        logger?("Fahrmoduswechsel angefordert: \(mode.title). Erst frische Geschwindigkeit und Register 0x75 lesen.")
        // The current telemetry request finishes first; the shared sender stays serialized.
    }
    private func advanceModeChange() {
        guard active, let transaction = modeChange else { return }
        switch transaction.phase {
        case .complete, .failed:
            modeChangeStatus = transaction.result
            logger?(modeChangeStatus)
            modeChangeBusy = false; modeChange = nil
            later(0.2) { [weak self] in self?.pollNext() }
        case .readyToWrite:
            guard let checkedAt = modeSpeedTime, Date().timeIntervalSince(checkedAt) < 3 else {
                modeChange?.fail("Stillstandsmessung zu alt; keine Änderung gesendet.")
                advanceModeChange(); return
            }
            modeChange?.markWriteSent()
            modeChangeStatus = "Sende \(transaction.target.title) einmal · danach Rückleseprüfung …"
            logger?("Fahrmodus: ein verschlüsselter CMD 02 an Controller 20, Register 75, Wert \(transaction.target.rawValue).")
            later(5) { [weak self] in self?.finish("Fahrmodus-Übertragung ohne Bestätigung; Ergebnis unbekannt. Am Display prüfen.") }
            send(command: 2, destination: 0x20, argument: 0x75, payload: transaction.target.payload)
        case .awaitingWrite: break
        case .speed, .current, .verify:
            guard let register = transaction.readRegister else { return }
            requestedRegister = register
            requestedConfiguration = false
            later(5) { [weak self] in
                guard let self = self, self.modeChangeBusy else { return }
                if !self.chunks.isEmpty { self.finish("Fahrmodus-Abfrage ohne Bluetooth-Bestätigung; Ergebnis ungeprüft."); return }
                self.requestedRegister = nil
                if transaction.phase == .verify { self.rideMode = nil }
                self.modeChange?.fail(transaction.phase == .verify
                    ? "Keine Rückleseantwort; Ergebnis unbekannt. Am Display prüfen. Keine erneute Änderung gesendet."
                    : "Keine Antwort vor der Änderung; kein Schreibbefehl gesendet.")
                self.advanceModeChange()
            }
            send(command: 1, destination: 0x20, argument: register, payload: [2])
        }
    }
    var report: String {
        let values = registers.compactMap { readings[$0] }.map {
            "\($0.title): \($0.text) · Alter \(Int(max(0, Date().timeIntervalSince($0.timestamp)))) s"
        }
        let measurements = values.isEmpty ? lastMeasurementReport : (["Messwerte:"] + values).joined(separator: "\n")
        let settings = configurationValues.keys.sorted().map {
            String(format: "Standardregister 0x%02X: 0x%04X · Bedeutung unter XiaoDash ungeprüft", $0, configurationValues[$0]!)
        }
        let missing = configurationAttempted.subtracting(configurationValues.keys).sorted().map {
            String(format: "Standardregister 0x%02X: keine bestätigte Antwort", $0)
        }
        return ([measurements, "Fahrmodus: \(rideMode?.title ?? "nicht aktuell bekannt")", modeChangeStatus, configurationStatus] + settings + missing).joined(separator: "\n")
    }
    private func buttonTick() {
        guard active, stage == "button" else { return }
        guard Date() < deadline else { finish("Kein bestätigter Tastendruck innerhalb von 30 Sekunden."); return }
        if chunks.isEmpty { send(command: 0x5C, payload: nonce) }
        if active { later(1) { [weak self] in self?.buttonTick() } }
    }
    private func authTick() {
        guard active, stage == "auth" else { return }
        guard Date() < deadline else { finish("Zeitlimit beim Abschluss der Anmeldung erreicht."); return }
        if !chunks.isEmpty { later(0.2) { [weak self] in self?.authTick() }; return }
        guard retries < 3 else { finish("Tastendruck bestätigt, Abschluss der Anmeldung fehlgeschlagen."); return }
        retries += 1
        send(command: 0x5D, payload: serial)
        if active { later(2) { [weak self] in self?.authTick() } }
    }
    func cancel() {
        if active { finish("Datenabfrage beendet.") }
    }
    func reset() {
        cancel()
        status = "Anmeldung noch nicht getestet."
    }
    private func finish(_ message: String) {
        timer?.cancel()
        if !readings.isEmpty {
            lastMeasurementReport = (["Letzte Messwerte vor Sitzungsende (nicht mehr live):"] + registers.compactMap { readings[$0] }.map { "\($0.title): \($0.text)" }).joined(separator: "\n")
        }
        active = false
        if modeChangeBusy { modeChangeStatus = "Fahrmoduswechsel unterbrochen; Ergebnis am Display prüfen." }
        modeChange = nil; modeChangeBusy = false; rideMode = nil; modeSpeedTime = nil
        authenticated = false
        readings = [:]; requestedRegister = nil
        if inspectingConfiguration {
            configurationStatus = "Leseprüfung unterbrochen · \(configurationCompleted)/\(Self.configurationRegisters.count) abgeschlossen."
        }
        configurationQueue = []; inspectingConfiguration = false
        stage = "idle"
        chunks = []; pendingReplies = []; buffer = []; nonce = []; serial = []; crypto = nil
        status = message
        logger?(message)
        if let peripheral = peripheral, let tx = tx { peripheral.setNotifyValue(false, for: tx) }
        peripheral = nil; tx = nil; rx = nil; logger = nil
    }
}


