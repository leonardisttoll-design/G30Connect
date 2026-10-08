// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct TelemetryReading {
    let title: String
    let value: Double
    let unit: String
    let timestamp: Date
    var text: String { String(format: unit == "%" ? "%.0f %@" : "%.2f %@", value, unit) }
    static func decode(register: UInt8, low: UInt8, high: UInt8) -> TelemetryReading? {
        let raw = Int16(bitPattern: UInt16(low) | UInt16(high) << 8)
        let title: String, unit: String, value: Double, range: ClosedRange<Double>
        switch register {
        case 0x22: title = "Akku"; unit = "%"; value = Double(raw); range = 0...100
        case 0x26: title = "Geschwindigkeit"; unit = "km/h"; value = Double(raw) / 10; range = -150...150
        case 0x3E: title = "Controller-Temperatur"; unit = "°C"; value = Double(raw) / 10; range = -40...150
        case 0x47: title = "Spannung"; unit = "V"; value = Double(raw) / 100; range = 10...100
        default: return nil
        }
        guard range.contains(value) else { return nil }
        return TelemetryReading(title: title, value: value, unit: unit, timestamp: Date())
    }
}
