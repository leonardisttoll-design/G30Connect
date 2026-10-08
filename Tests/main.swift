import Foundation

// Independently generated .NET AES/SHA1 vectors; all names/keys are synthetic.
func bytes(_ hex: String) -> [UInt8] {
    let chars = Array(hex)
    return stride(from: 0, to: chars.count, by: 2).map {
        UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
    }
}
func require(_ test: Bool, _ reason: String) {
    if !test { fatalError(reason) }
}
let crypto = NinebotSessionCrypto(name: "NBScooterTEST")
let hello = crypto.encrypt(command: 0x5B, destination: 0x21, argument: 0)
require(hello == Data(bytes("5AA50064C1CCE3000045FF0000")), "Initial packet differs from .NET vector")
let helloReply = bytes("5AA51E7BDECCE3B359D1A8ADC32E586D6FB08257EE98F3E61E81F899F71A6451538CB663D0000070FB0000")
require(crypto.decrypt([]) == nil, "Empty frame accepted")
require(crypto.decrypt(Array(helloReply.dropLast())) == nil, "Truncated frame accepted")
var invalid = helloReply
invalid[invalid.count - 4] ^= 1
require(crypto.decrypt(invalid) == nil, "Damaged initial checksum accepted")
let decoded = crypto.decrypt(helloReply)
require(decoded?.suffix(14) == Array("TEST1234567890".utf8).suffix(14), "Hello reply not decrypted")
require(crypto.decrypt(helloReply) == nil, "Replay accepted")
let nonce = Array(UInt8(33)...UInt8(48))
let request = crypto.encrypt(command: 0x5C, destination: 0x21, argument: 0, payload: nonce)
require(request == Data(bytes("5AA5108A56BA0EC72859FF693DB0366BC66A469C82C8FCCADD6A730002")), "Button request differs from vector")
let ack = bytes("5AA500CCAEA079AD70FF300003")
var badAck = ack
badAck[7] ^= 1
require(crypto.decrypt(badAck) == nil, "Invalid authentication tag accepted")
require(crypto.decrypt(ack) == bytes("5AA500213E5C01"), "Button acknowledgement not decrypted")
let auth = crypto.encrypt(command: 0x5D, destination: 0x21, argument: 0, payload: Array("TEST1234567890".utf8))
require(auth == Data(bytes("5AA50E2BE09AE3CE9DBE164C07136703B824D96C1637922FB60004")), "Final authentication packet differs from vector")
print("Crypto vectors, truncation, corruption and replay checks passed.")
require(TelemetryReading.decode(register: 0x22, low: 35, high: 0)?.value == 35, "Battery percentage decoding failed")
require(TelemetryReading.decode(register: 0x26, low: 253, high: 0)?.value == 25.3, "Speed scale failed")
require(TelemetryReading.decode(register: 0x3E, low: 206, high: 255)?.value == -5, "Signed temperature decoding failed")
require(TelemetryReading.decode(register: 0x47, low: 38, high: 14)?.value == 36.22, "Voltage scale or byte order failed")
require(TelemetryReading.decode(register: 0x22, low: 101, high: 0) == nil, "Invalid battery accepted")
require(TelemetryReading.decode(register: 0x47, low: 0, high: 0) == nil, "Invalid voltage accepted")
require(TelemetryReading.decode(register: 0x99, low: 0, high: 0) == nil, "Unknown register accepted")
print("Telemetry signed decoding, byte order, scaling and plausibility checks passed.")
