// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreBluetooth
import Security
import Combine

final class PairingTest: ObservableObject {
    @Published var active = false
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
        nonce = [UInt8](repeating: 0, count: 16)
        let randomResult = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard randomResult == errSecSuccess else { finish("Zufallsschlüssel konnte nicht erzeugt werden."); return }
        active = true
        stage = "subscribe"
        status = "Aktiviere Empfang für die verschlüsselte Anmeldung …"
        log("Anmeldetest 0.4 gestartet. Keine Schlüssel, Seriennummern oder Anmelde-Rohpakete im Bericht.")
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
            finish(String(format: "Anmeldung und verschlüsselte Abfrage erfolgreich · Versionsregister 0x%04X (Override möglich).", value))
        }
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
        if active { finish("Anmeldetest beendet.") }
    }
    func reset() {
        cancel()
        status = "Anmeldung noch nicht getestet."
    }
    private func finish(_ message: String) {
        timer?.cancel()
        active = false
        stage = "idle"
        chunks = []; pendingReplies = []; buffer = []; nonce = []; serial = []; crypto = nil
        status = message
        logger?(message)
        if let peripheral = peripheral, let tx = tx { peripheral.setNotifyValue(false, for: tx) }
        peripheral = nil; tx = nil; rx = nil; logger = nil
    }
}

