import Foundation

/// API client credentials obtained from SoundCloud's `sc-api-auth.mjs` CLI,
/// read from `~/.config/reed/credentials.json` (kept out of source).
///
/// ```json
/// {
///   "client_id": "...",
///   "client_secret": "...",
///   "redirect_uri": "reed://callback"
/// }
/// ```
struct AppCredentials: Codable {
    let clientID: String
    let clientSecret: String
    let redirectURI: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case redirectURI = "redirect_uri"
    }

    static let defaultRedirectURI = "reed://callback"

    init(clientID: String, clientSecret: String, redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    /// Tolerant of the `sc-api-auth.mjs` JSON output: extra keys (name,
    /// description, website) are ignored, and `redirect_uri` falls back to the
    /// loopback default when the CLI doesn't report one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        clientSecret = try container.decode(String.self, forKey: .clientSecret)
        redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI)
            ?? Self.defaultRedirectURI
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/reed/credentials.json")
    }

    static func load() -> AppCredentials? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(AppCredentials.self, from: data)
    }

    /// Write `credentials.json` (used by the in-app Connect flow), 0600.
    static func save(_ credentials: AppCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: configURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
