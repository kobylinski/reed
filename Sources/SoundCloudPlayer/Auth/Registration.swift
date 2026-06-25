import Foundation
import AppKit

/// In-app credential registration — the native equivalent of SoundCloud's
/// `sc-api-auth.mjs`. Signs the user in with SoundCloud's public registration
/// client, calls `POST /me/apps`, and returns fresh app credentials.
///
/// Requires an Artist Pro account (SoundCloud gates app registration to it).
enum Registration {
    // SoundCloud's published registration client (from sc-api-auth.mjs).
    private static let clientID = "nXIZT4VQQYkgHs75vpIYbnINQciCkV5Y"
    private static let redirectURI = "http://127.0.0.1:8765/callback"
    private static let port: UInt16 = 8765
    private static let authorizeURL = URL(string: "https://secure.soundcloud.com/authorize")!
    private static let tokenURL = URL(string: "https://secure.soundcloud.com/oauth/token")!
    private static let appsURL = URL(string: "https://api-reg.soundcloud.com/me/apps")!

    /// The redirect URI our app uses for its own login (must be registered at the
    /// portal afterwards — the API won't let us set it programmatically).
    static let appRedirectURI = "soundcloudplayer://callback"

    private static var loopback: LoopbackServer?

    static func register(name: String, description: String, website: String) async throws -> AppCredentials {
        let token = try await signIn()
        let app = try await createOrFetchApp(token: token, name: name, description: description, website: website)
        return AppCredentials(clientID: app.clientID, clientSecret: app.clientSecret, redirectURI: appRedirectURI)
    }

    // MARK: OAuth (registration client, loopback)

    private static func signIn() async throws -> String {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomState()

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        let authorize = components.url!

        let params: [String: String] = try await withCheckedThrowingContinuation { continuation in
            let server = LoopbackServer(port: port)
            loopback = server
            do {
                try server.start { continuation.resume(with: $0) }
                NSWorkspace.shared.open(authorize)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        loopback = nil

        if let error = params["error"] { throw AuthError.server(error) }
        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.noCode }

        return try await exchange(code: code, verifier: verifier)
    }

    private static func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.httpBody = form([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "code": code
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.server(String(data: data, encoding: .utf8) ?? "token exchange failed")
        }
        struct TokenResponse: Decodable {
            let accessToken: String
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data).accessToken
    }

    // MARK: App registration

    private struct App: Decodable {
        let clientID: String
        let clientSecret: String
        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }
    }

    private static func createOrFetchApp(token: String, name: String, description: String, website: String) async throws -> App {
        var request = URLRequest(url: appsURL)
        request.httpMethod = "POST"
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "description": description, "website": website])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.server("No HTTP response") }

        if http.statusCode == 201 {
            return try JSONDecoder().decode(App.self, from: data)
        }
        if http.statusCode == 403 {
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("user_already_has_application") {
                return try await fetchExistingApp(token: token)
            }
            throw AuthError.server("Registration not available for your account. This requires a SoundCloud Artist Pro subscription.")
        }
        throw AuthError.server("Create app failed (HTTP \(http.statusCode)): \(String(data: data, encoding: .utf8) ?? "")")
    }

    private static func fetchExistingApp(token: String) async throws -> App {
        var request = URLRequest(url: appsURL)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Page: Decodable { let collection: [App] }
        if let page = try? JSONDecoder().decode(Page.self, from: data), let app = page.collection.first {
            return app
        }
        if let app = try? JSONDecoder().decode(App.self, from: data) { return app }
        throw AuthError.server("Could not read your existing application credentials.")
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}
