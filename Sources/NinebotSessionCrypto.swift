// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from scooterhacking/NinebotCrypto (C++ and Swift implementations).
// Upstream Swift authors: Robert Trencheny (2020), Lex Nastin (2023).
// G30 Connect changes: bounds checks, authentication tag verification,
// no secret logging, CommonCrypto AES, explicit initial-message state.
import Foundation
import CommonCrypto
import CryptoKit

final class NinebotSessionCrypto {
    private static let firmwareMagic: [UInt8] = [0x97,0xCF,0xB8,0x02,0x84,0x41,0x43,0xDE,0x56,0x00,0x2B,0x3B,0x34,0x78,0x0A,0x5D]
    private let name: [UInt8]
    private var key: [UInt8]
    private var bleRandom = [UInt8](repeating: 0, count: 16)
    private var appRandom = [UInt8](repeating: 0, count: 16)
    private var counter: UInt32 = 0
    private var firstOutbound = true
    private var lastReceived: UInt32?

    init(name: String) {
        let nameBytes = Self.padded(Array(name.utf8))
        self.name = nameBytes
        self.key = Self.derive(nameBytes, Self.firmwareMagic)
    }
    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        Array((bytes + [UInt8](repeating: 0, count: 16)).prefix(16))
    }
    private static func derive(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: Data(padded(a) + padded(b))).prefix(16))
    }
    private func aes(_ block: [UInt8]) -> [UInt8]? {
        guard block.count == 16, key.count == 16 else { return nil }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let result = key.withUnsafeBytes { k in
            block.withUnsafeBytes { b in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, 16, nil, b.baseAddress, 16, o.baseAddress, 16, &moved)
                }
            }
        }
        return result == kCCSuccess && moved == 16 ? out : nil
    }
    private func iv(_ count: UInt32, kind: UInt8, length: UInt8) -> [UInt8] {
        [kind, UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
         UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)]
        + Array(bleRandom.prefix(8)) + [0, 0, length]
    }
    private func crypt(_ payload: [UInt8], count: UInt32) -> [UInt8]? {
        var result: [UInt8] = []
        var vector = count == 0 ? Self.firmwareMagic : iv(count, kind: 1, length: 0)
        for start in stride(from: 0, to: payload.count, by: 16) {
            if count > 0 { vector[15] &+= 1 }
            guard let stream = aes(vector) else { return nil }
            let chunk = Array(payload[start..<min(start + 16, payload.count)])
            result += zip(chunk, stream).map { $0.0 ^ $0.1 }
        }
        return result
    }
    private func tag(_ plain: [UInt8], count: UInt32) -> [UInt8]? {
        if count == 0 {
            let sum = plain.dropFirst(3).reduce(UInt16(0)) { $0 &+ UInt16($1) }
            let crc = ~sum
            return [0, 0, UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
        }
        guard plain.count >= 7, plain.count - 3 <= 255 else { return nil }
        var vector = iv(count, kind: 0x59, length: UInt8(plain.count - 3))
        guard let initial = aes(vector) else { return nil }
        let header = Self.padded(Array(plain.prefix(3)))
        guard var state = aes(zip(header, initial).map { $0.0 ^ $0.1 }) else { return nil }
        for start in stride(from: 3, to: plain.count, by: 16) {
            let block = Self.padded(Array(plain[start..<min(start + 16, plain.count)]))
            guard let next = aes(zip(block, state).map { $0.0 ^ $0.1 }) else { return nil }
            state = next
        }
        vector[0] = 1
        vector[15] = 0
        guard let mask = aes(vector) else { return nil }
        return Array(zip(state, mask).map { $0.0 ^ $0.1 }.prefix(4))
    }
    func encrypt(command: UInt8, destination: UInt8, argument: UInt8, payload: [UInt8] = []) -> Data? {
        guard payload.count <= 242, counter < UInt32.max - 1 else { return nil }
        let count: UInt32
        if firstOutbound { count = 0; firstOutbound = false; counter = 1 }
        else { counter += 1; count = counter }
        let plain: [UInt8] = [0x5A,0xA5,UInt8(payload.count),0x3E,destination,command,argument] + payload
        guard let encrypted = crypt(Array(plain.dropFirst(3)), count: count), let auth = tag(plain, count: count) else { return nil }
        if command == 0x5C, payload.count == 16 { appRandom = payload }
        return Data(Array(plain.prefix(3)) + encrypted + auth
                    + [UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
    }
    func decrypt(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 13, frame[0] == 0x5A, frame[1] == 0xA5,
              frame.count == Int(frame[2]) + 13 else { return nil }
        let low = UInt32(frame[frame.count - 2]) << 8 | UInt32(frame[frame.count - 1])
        var high = counter & 0xFFFF0000
        if counter & 0x8000 != 0, low & 0x8000 == 0 { high &+= 0x10000 }
        let count = high | low
        if let previous = lastReceived, count <= previous { return nil }
        guard let decoded = crypt(Array(frame[3..<(frame.count - 6)]), count: count) else { return nil }
        let plain = Array(frame.prefix(3)) + decoded
        guard let expected = tag(plain, count: count) else { return nil }
        let actual = Array(frame[(frame.count - 6)..<(frame.count - 2)])
        guard zip(expected, actual).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0,
              plain[3] == 0x21 || plain[3] == 0x20, plain[4] == 0x3E else { return nil }
        lastReceived = count
        if count > counter { counter = count }
        if plain[3] == 0x21, plain[5] == 0x5B, plain[2] == 30, count == 0 {
            bleRandom = Array(plain[7..<23])
            key = Self.derive(name, bleRandom)
        }
        if plain[3] == 0x21, plain[5] == 0x5C, plain[6] == 1, plain[2] == 0 {
            key = Self.derive(appRandom, bleRandom)
        }
        return plain
    }
}

