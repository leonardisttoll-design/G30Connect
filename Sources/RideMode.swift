// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum RideMode: UInt16, CaseIterable, Identifiable {
    case normal = 0, eco = 1, sport = 2
    var id: UInt16 { rawValue }
    var title: String {
        switch self { case .normal: return "Drive"; case .eco: return "Eco"; case .sport: return "Sport" }
    }
    var payload: [UInt8] { [UInt8(rawValue), 0] }
}

// Read speed and current mode before a single write. Only readback confirms the result.
struct ModeChangeTransaction {
    enum Phase: Equatable { case speed, current, readyToWrite, awaitingWrite, verify, complete, failed }
    let target: RideMode
    private(set) var phase: Phase = .speed
    private(set) var result = ""
    var readRegister: UInt8? {
        switch phase { case .speed: return 0x26; case .current, .verify: return 0x75; default: return nil }
    }
    mutating func accept(register: UInt8, value: UInt16) {
        guard register == readRegister else { return }
        switch phase {
        case .speed:
            guard abs(Int(Int16(bitPattern: value))) <= 1 else { fail("Scooter bewegt sich; keine Änderung gesendet."); return }
            phase = .current
        case .current:
            guard let current = RideMode(rawValue: value) else { fail("Unbekannter Fahrmodus; keine Änderung gesendet."); return }
            if current == target { phase = .complete; result = "\(target.title) ist bereits eingestellt." }
            else { phase = .readyToWrite }
        case .verify:
            guard value == target.rawValue else { fail("Zurückgelesener Modus stimmt nicht mit \(target.title) überein. Keine erneute Änderung gesendet."); return }
            phase = .complete; result = "\(target.title) vom Scooter zurückgelesen."
        default: break
        }
    }
    mutating func markWriteSent() {
        guard phase == .readyToWrite else { return }
        phase = .awaitingWrite
    }
    mutating func transmissionCompleted() {
        guard phase == .awaitingWrite else { return }
        phase = .verify
    }
    mutating func fail(_ message: String) { phase = .failed; result = message }
}
