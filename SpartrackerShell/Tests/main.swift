import Foundation

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
}
func fails(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected rejection: \(label)") } catch { }
}

let publicJSON = #"{"users":[{"username":"example-user","totalXp":900000,"courses":[{"id":"fr_de","learningLanguage":"fr","fromLanguage":"de","xp":897},{"id":"en_de","learningLanguage":"en","fromLanguage":"de","xp":99999},{"id":"bad","learningLanguage":"fr","xp":true},{"id":"bad2","learningLanguage":"fr","xp":3.5}]}]}"#
let profile = try DuolingoClient.parse(data: Data(publicJSON.utf8), requestedUsername: "example-user")
check(profile.courses.count == 1, "Only valid French courses")
check(profile.courses[0].xp == 897, "Course XP, never totalXP")
check(profile.courses[0].label == "Deutsch → Französisch", "Language label")
let multiple = publicJSON.replacingOccurrences(of: "\"xp\":3.5", with: "\"xp\":400")
let multipleProfile = try DuolingoClient.parse(data: Data(multiple.utf8), requestedUsername: "example-user")
check(multipleProfile.courses.count == 2, "Preserve multiple French options")
fails("Missing profile") { _ = try DuolingoClient.parse(data: Data(#"{"users":[]}"#.utf8), requestedUsername: "x") }
fails("Malformed response") { _ = try DuolingoClient.parse(data: Data("<html>error</html>".utf8), requestedUsername: "x") }
check(!DuolingoClient.isValidUsername("bad user"), "Username validation")

let backup = #"{"version":1,"username":"example-user","xp":897,"linked":true,"courseId":"DUOLINGO_FR_DE","courseLabel":"Deutsch → Französisch","updatedAt":"2020-01-01T01:00:00.000Z","history":[{"xp":897,"previousXp":802,"time":"2020-01-01T01:00:00Z","source":"duolingo"}]}"#
try TrackerBackupStore.validate(backup)
fails("Boolean XP") { try TrackerBackupStore.validate(backup.replacingOccurrences(of: "\"xp\":897", with: "\"xp\":true")) }
fails("Missing course") { try TrackerBackupStore.validate(backup.replacingOccurrences(of: "DUOLINGO_FR_DE", with: "")) }
fails("Wrong version") { try TrackerBackupStore.validate(backup.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")) }
fails("Fractional XP") { try TrackerBackupStore.validate(backup.replacingOccurrences(of: "\"xp\":897", with: "\"xp\":897.5")) }
fails("Oversized backup") { try TrackerBackupStore.validate(String(repeating: "x", count: 1_000_001)) }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let store = try TrackerBackupStore(directory: directory)
check(store.initialState() == nil, "Fresh state")
try store.save(backup)
check(store.initialState() == backup, "Atomic persistence and restart restore")
fails("Invalid write") { try store.save("invalid") }
check(store.initialState() == backup, "Failed write preserves saved state")
print("Duolingo profile and backup checks passed.")
