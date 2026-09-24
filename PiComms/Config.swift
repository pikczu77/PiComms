import Foundation

enum Config {
    /// Client ID typu „iOS” z Google Cloud Console (APIs & Services → Credentials).
    /// Zobacz README.md – sekcja „Konfiguracja Google Cloud”.
    static let googleClientID = "TWOJ_CLIENT_ID.apps.googleusercontent.com"

    /// Odwrócony client ID – Google używa go jako schematu URL do powrotu z logowania.
    static var redirectScheme: String {
        let prefix = googleClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }

    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    static var isConfigured: Bool { !googleClientID.hasPrefix("TWOJ_CLIENT_ID") }

    /// Pełny dostęp do Drive jest potrzebny, żeby druga osoba widziała pliki
    /// utworzone przez Ciebie we wspólnym folderze (zakres drive.file na to nie pozwala).
    static let scopes = ["https://www.googleapis.com/auth/drive"]

    static let chatFolderName = "PiComms"

    /// Jak często aplikacja sprawdza nowe wiadomości, gdy jest otwarta.
    static let pollInterval: Duration = .seconds(3)
}
