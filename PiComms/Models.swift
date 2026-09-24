import Foundation

struct Message: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case sent, sending, failed
    }

    /// Identyfikator nadawany przez aplikację (ten sam na obu telefonach).
    let id: String
    /// E-mail nadawcy (małymi literami).
    let sender: String
    let text: String
    var date: Date
    var status: Status = .sent
}

/// Zawartość pliku wiadomości na Google Drive.
struct MessagePayload: Codable {
    let id: String
    let sender: String
    let text: String
    let sentAt: Date
}

/// Zawartość pliku profilu na Google Drive (jeden plik na osobę).
struct Profile: Codable, Equatable {
    var email: String
    var displayName: String
    /// Zdjęcie profilowe jako JPEG (w JSON zapisane w base64).
    var avatar: Data?
    var updatedAt: Date
}

extension JSONEncoder {
    static let drive: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let drive: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum RFC3339 {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return withFraction.date(from: string) ?? plain.date(from: string)
    }

    static func string(from date: Date) -> String {
        withFraction.string(from: date)
    }
}
