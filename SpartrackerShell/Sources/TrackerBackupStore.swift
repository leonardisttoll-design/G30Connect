import Foundation
import CoreFoundation

enum BackupError: LocalizedError {
    case invalid, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: return "Das ist keine gültige Duolingo-Spartracker-Sicherung."
        case .tooLarge: return "Die Sicherungsdatei ist zu groß."
        case .unavailable: return "Deine App-Daten konnten nicht gespeichert werden. Teile bitte eine Sicherung."
        }
    }
}

struct TrackerBackupStore {
    static let maximumBytes = 1_000_000
    private let fileURL: URL

    init(directory: URL? = nil) throws {
        let directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DuolingoSpartracker", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("tracker-v1.json")
    }

    func initialState() -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        // An unreadable existing record must not look like a fresh installation.
        guard let data = try? Data(contentsOf: fileURL), data.count <= Self.maximumBytes,
              let json = String(data: data, encoding: .utf8) else { return "invalid-existing-backup" }
        return json
    }

    func save(_ json: String) throws {
        let data = try Self.validate(json)
        do { try data.write(to: fileURL, options: .atomic) }
        catch { throw BackupError.unavailable }
    }

    @discardableResult static func validate(_ json: String) throws -> Data {
        let data = Data(json.utf8)
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(root["version"], maximum: 1) == 1,
              let username = root["username"] as? String, username.utf16.count <= 80,
              integer(root["xp"]) != nil,
              let linkedNumber = root["linked"] as? NSNumber,
              CFGetTypeID(linkedNumber) == CFBooleanGetTypeID(),
              let courseID = root["courseId"] as? String, courseID.utf16.count <= 200,
              let label = root["courseLabel"] as? String, label.utf16.count <= 200,
              let updated = root["updatedAt"], updated is NSNull || validDate(updated),
              let history = root["history"] as? [[String: Any]], history.count <= 1000
        else { throw BackupError.invalid }
        if linkedNumber.boolValue && (username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || courseID.isEmpty) {
            throw BackupError.invalid
        }
        for item in history {
            guard integer(item["xp"]) != nil, validDate(item["time"]),
                  let source = item["source"] as? String, ["duolingo", "manual"].contains(source),
                  item["previousXp"] == nil || integer(item["previousXp"]) != nil
            else { throw BackupError.invalid }
        }
        return data
    }

    private static func integer(_ value: Any?, maximum: Int = 100_000_000) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let n = number.doubleValue
        guard n.isFinite, n >= 0, n <= Double(maximum), n.rounded(.towardZero) == n else { return nil }
        return Int(n)
    }

    private static func validDate(_ value: Any?) -> Bool {
        guard let string = value as? String, string.utf8.count < 100 else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: string) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string) != nil
    }
}
