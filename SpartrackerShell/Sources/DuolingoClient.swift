import Foundation
import CoreFoundation

struct DuolingoCourse: Codable, Sendable {
    let id: String
    let label: String
    let xp: Int
}

struct DuolingoProfile: Codable, Sendable {
    let username: String
    let courses: [DuolingoCourse]
}

enum DuolingoClientError: LocalizedError, Sendable {
    case invalidUsername
    case alreadyFetching
    case unavailable
    case profileNotFound
    case noFrenchCourse
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return "Bitte gib einen gültigen Duolingo-Benutzernamen ein."
        case .alreadyFetching:
            return "Dein Duolingo-Profil wird bereits aktualisiert."
        case .unavailable:
            return "Duolingo erlaubt den Abruf gerade nicht. Dein letzter Stand bleibt erhalten. Versuche es später erneut oder trage deine XP selbst ein."
        case .profileNotFound:
            return "Dieses öffentliche Profil wurde nicht gefunden. Prüfe den genauen Benutzernamen. Ein privates Profil kannst du manuell verfolgen."
        case .noFrenchCourse:
            return "In diesem Profil sind keine öffentlichen Französisch-XP verfügbar. Du kannst deinen Französisch-Stand selbst eintragen."
        case .invalidResponse:
            return "Duolingo hat keine gültigen Kursdaten geliefert. Dein letzter Stand bleibt erhalten."
        case .timedOut:
            return "Duolingo antwortet gerade nicht. Dein letzter Stand bleibt erhalten. Die App versucht es automatisch erneut."
        }
    }

    var statusCode: Int {
        switch self {
        case .invalidUsername: return 400
        case .alreadyFetching: return 409
        case .profileNotFound, .noFrenchCourse: return 404
        case .timedOut: return 504
        case .unavailable, .invalidResponse: return 502
        }
    }
}

/// Reads public course XP only. A separate ephemeral session deliberately sends no
/// Duolingo login cookies, stored credentials, or browser session information.
/// The actor rejects overlapping requests; the WebView owns foreground polling.
actor DuolingoClient {
    static let requestDeadline: TimeInterval = 4.5
    static let maximumXP = 100_000_000
    static let maximumResponseBytes = 1_000_000

    private let session: URLSession
    private var isFetching = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestDeadline
        configuration.timeoutIntervalForResource = Self.requestDeadline
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }

    func fetch(username: String) async throws -> DuolingoProfile {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidUsername(name) else {
            throw DuolingoClientError.invalidUsername
        }
        guard !isFetching else { throw DuolingoClientError.alreadyFetching }
        isFetching = true
        defer { isFetching = false }

        var components = URLComponents(string: "https://www.duolingo.com/2017-06-30/users")!
        components.queryItems = [
            URLQueryItem(name: "username", value: name),
            URLQueryItem(name: "fields", value: "users{username,courses{id,title,learningLanguage,fromLanguage,xp}}")
        ]
        guard let url = components.url else { throw DuolingoClientError.invalidUsername }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestDeadline)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false

        do {
            let (data, response) = try await fetchBeforeDeadline(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw DuolingoClientError.invalidResponse
            }
            guard (200...299).contains(response.statusCode) else {
                throw DuolingoClientError.unavailable
            }
            return try Self.parse(data: data, requestedUsername: name)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DuolingoClientError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw DuolingoClientError.timedOut
        } catch {
            throw DuolingoClientError.unavailable
        }
    }

    /// Resource timeout also bounds the response body; this race additionally
    /// applies one wall-clock deadline even if the server sends a slow stream.
    private func fetchBeforeDeadline(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let requestSession = session
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await requestSession.data(for: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: 4_500_000_000)
                throw DuolingoClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw DuolingoClientError.unavailable
            }
            return response
        }
    }

    static func isValidUsername(_ username: String) -> Bool {
        !username.isEmpty && username.utf16.count <= 80 &&
        !username.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) ||
            CharacterSet.controlCharacters.contains($0)
        }
    }

    /// Kept separate from networking so malformed/mixed public profiles can be
    /// tested without requesting Duolingo or requiring an Apple account.
    static func parse(data: Data, requestedUsername: String) throws -> DuolingoProfile {
        guard data.count <= maximumResponseBytes else {
            throw DuolingoClientError.invalidResponse
        }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: data) }
        catch { throw DuolingoClientError.invalidResponse }
        guard let root = decoded as? [String: Any],
              let users = root["users"] as? [Any] else {
            throw DuolingoClientError.invalidResponse
        }
        guard let user = users.first as? [String: Any] else {
            throw DuolingoClientError.profileNotFound
        }
        let canonicalName = user["username"] as? String
        let profileName = canonicalName.flatMap { isValidUsername($0) ? $0 : nil } ?? requestedUsername
        let languageNames = [
            "de": "Deutsch", "en": "Englisch", "es": "Spanisch",
            "it": "Italienisch", "pt": "Portugiesisch", "nl": "Niederländisch",
            "ru": "Russisch", "ja": "Japanisch", "zh": "Chinesisch",
            "ko": "Koreanisch", "ar": "Arabisch"
        ]
        let rawCourses = user["courses"] as? [Any] ?? []
        var seenIDs = Set<String>()
        var courses: [DuolingoCourse] = []
        for value in rawCourses {
            guard let course = value as? [String: Any],
                  course["learningLanguage"] as? String == "fr",
                  let id = course["id"] as? String,
                  !id.isEmpty, id.utf16.count <= 200,
                  let number = course["xp"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let xpValue = number.doubleValue
            guard xpValue.isFinite, xpValue.rounded(.towardZero) == xpValue,
                  xpValue >= 0, xpValue <= Double(maximumXP),
                  seenIDs.insert(id).inserted else { continue }
            let languageCode = course["fromLanguage"] as? String ?? ""
            let language = languageNames[languageCode] ??
                (languageCode.isEmpty ? "Ausgangssprache" : String(languageCode.prefix(80)))
            courses.append(DuolingoCourse(id: id, label: "\(language) → Französisch", xp: Int(xpValue)))
        }
        guard !courses.isEmpty else { throw DuolingoClientError.noFrenchCourse }
        // Return every French course. Selecting one belongs to the frontend and
        // must stay explicit when the profile contains multiple French courses.
        return DuolingoProfile(username: profileName, courses: courses)
    }
}
