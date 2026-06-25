import Foundation
import AppKit

enum AuthError: LocalizedError {
    case missingCredentials
    case notAuthenticated
    case stateMismatch
    case noCode
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No API credentials. Run sc-api-auth.mjs, then create ~/.config/reed/credentials.json."
        case .notAuthenticated:
            return "Not signed in to SoundCloud."
        case .stateMismatch:
            return "OAuth state mismatch — login aborted."
        case .noCode:
            return "SoundCloud did not return an authorization code."
        case .server(let message):
            return "SoundCloud error: \(message)"
        }
    }
}

/// Owns the OAuth 2.1 + PKCE login flow and the access/refresh token lifecycle.
/// All access happens on the main thread (menu actions / `@MainActor` tasks).
final class SoundCloudAuth {
    private static let authorizeURL = URL(string: "https://secure.soundcloud.com/authorize")!
    private static let tokenURL = URL(string: "https://secure.soundcloud.com/oauth/token")!

    private let credentials: AppCredentials
    private var tokens: TokenSet?

    /// Resumed when the `reed://callback` URL is delivered to the app.
    private var pendingRedirect: CheckedContinuation<[String: String], Error>?

    var isAuthenticated: Bool { tokens != nil }

    /// Returns nil when no credentials file exists yet.
    init?() {
        guard let credentials = AppCredentials.load() else { return nil }
        self.credentials = credentials
        self.tokens = TokenStore.load()
    }

    // MARK: Login

    func login() async throws {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomState()

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: credentials.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        let authorizeURL = components.url!

        // Open the system browser and wait for SoundCloud to redirect back to
        // our custom scheme, which the app receives via `handleRedirect(_:)`.
        let params = try await withCheckedThrowingContinuation { continuation in
            pendingRedirect = continuation
            NSWorkspace.shared.open(authorizeURL)
        }

        if let error = params["error"] { throw AuthError.server(error) }
        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.noCode }

        let tokens = try await requestToken([
            "grant_type": "authorization_code",
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "redirect_uri": credentials.redirectURI,
            "code_verifier": verifier,
            "code": code
        ])
        store(tokens)
    }

    /// Called by AppDelegate when the OS hands the app a `reed://`
    /// URL. Idempotent — a duplicate delivery after the first is ignored, so it
    /// can never double-resume the continuation.
    func handleRedirect(_ url: URL) {
        guard let continuation = pendingRedirect else { return }
        pendingRedirect = nil
        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            params[item.name] = item.value
        }
        continuation.resume(returning: params)
    }

    // MARK: Token access

    /// A valid access token, refreshing transparently when near expiry.
    func validAccessToken() async throws -> String {
        guard let current = tokens else { throw AuthError.notAuthenticated }
        guard current.isExpired else { return current.accessToken }
        let refreshed = try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret
        ])
        store(refreshed)
        return refreshed.accessToken
    }

    /// Force a token refresh regardless of expiry — used when the API returns 401
    /// (e.g. the token was revoked server-side before its nominal expiry).
    func forceRefresh() async throws -> String {
        guard let current = tokens else { throw AuthError.notAuthenticated }
        let refreshed = try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret
        ])
        store(refreshed)
        return refreshed.accessToken
    }

    func logout() {
        tokens = nil
        TokenStore.clear()
    }

    // MARK: Internals

    private func store(_ tokens: TokenSet) {
        self.tokens = tokens
        TokenStore.save(tokens)
    }

    private func requestToken(_ form: [String: String]) async throws -> TokenSet {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.httpBody = Self.encodeForm(form)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.server(String(data: data, encoding: .utf8) ?? "token request failed")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenSet(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        )
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private static func encodeForm(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}
