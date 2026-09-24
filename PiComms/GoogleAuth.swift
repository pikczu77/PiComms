import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum AuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case cancelled
    case invalidCallback
    case invalidGrant
    case tokenRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Uzupełnij googleClientID w pliku Config.swift."
        case .notSignedIn: "Nie jesteś zalogowany."
        case .cancelled: "Logowanie anulowane."
        case .invalidCallback: "Nieprawidłowa odpowiedź z logowania Google."
        case .invalidGrant: "Sesja wygasła – zaloguj się ponownie."
        case .tokenRequestFailed(let body): "Błąd logowania Google: \(body)"
        }
    }
}

/// Logowanie Google przez OAuth 2.0 z PKCE (bez zewnętrznych bibliotek).
/// Tokeny są trzymane w Keychain, access token jest odświeżany automatycznie.
@MainActor
@Observable
final class GoogleAuth {
    private(set) var isSignedIn: Bool

    @ObservationIgnored private var tokens: OAuthTokens?
    @ObservationIgnored private var refreshTask: Task<OAuthTokens, Error>?
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter = PresentationAnchorProvider()

    private static let keychainAccount = "google-oauth-tokens"

    init() {
        if let data = Keychain.load(account: Self.keychainAccount),
           let saved = try? JSONDecoder().decode(OAuthTokens.self, from: data) {
            tokens = saved
            isSignedIn = true
        } else {
            isSignedIn = false
        }
    }

    func signIn() async throws {
        guard Config.isConfigured else { throw AuthError.notConfigured }

        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 16)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Config.googleClientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: Config.redirectScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.invalidCallback)
                }
            }
            presenter.anchor = Self.keyWindow()
            session.presentationContextProvider = presenter
            webSession = session
            session.start()
        }
        webSession = nil

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw AuthError.invalidCallback }

        let response = try await Self.tokenRequest([
            "code": code,
            "client_id": Config.googleClientID,
            "redirect_uri": Config.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refreshToken = response.refresh_token else {
            throw AuthError.tokenRequestFailed("brak refresh tokena")
        }
        setTokens(OAuthTokens(
            accessToken: response.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(response.expires_in)
        ))
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        setTokens(nil)
    }

    /// Zwraca ważny access token, w razie potrzeby odświeżając go.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        if !forceRefresh, tokens.expiresAt > Date().addingTimeInterval(60) {
            return tokens.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        let refreshToken = tokens.refreshToken
        let task = Task { () throws -> OAuthTokens in
            let response = try await Self.tokenRequest([
                "client_id": Config.googleClientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ])
            return OAuthTokens(
                accessToken: response.access_token,
                refreshToken: response.refresh_token ?? refreshToken,
                expiresAt: Date().addingTimeInterval(response.expires_in)
            )
        }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let fresh = try await task.value
            setTokens(fresh)
            return fresh.accessToken
        } catch AuthError.invalidGrant {
            signOut()
            throw AuthError.invalidGrant
        }
    }

    private func setTokens(_ newValue: OAuthTokens?) {
        tokens = newValue
        if let newValue, let data = try? JSONEncoder().encode(newValue) {
            Keychain.save(data, account: Self.keychainAccount)
        } else {
            Keychain.delete(account: Self.keychainAccount)
        }
        isSignedIn = newValue != nil
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private nonisolated static func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            if status == 400 || status == 401, body.contains("invalid_grant") {
                throw AuthError.invalidGrant
            }
            throw AuthError.tokenRequestFailed(body)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private nonisolated static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func keyWindow() -> UIWindow {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? UIWindow()
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    var anchor: ASPresentationAnchor?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor!
    }
}
