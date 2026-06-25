import Foundation

/// OAuth tokens with a refresh deadline.
struct TokenSet: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// True within 60s of expiry, so we refresh proactively.
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Persists the `TokenSet` as a 0600 JSON file under Application Support.
///
/// Why not Keychain? This app is currently ad-hoc signed (no full Xcode / signing
/// identity), and macOS scopes Keychain items to a stable code signature — so a
/// rebuild can't read what the previous build saved, silently logging the user
/// out. A file keeps the session across rebuilds. Revisit Keychain once the app
/// has a Developer ID signing identity.
enum TokenStore {
    private static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("soundcloudplayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tokens.json")
    }

    static func save(_ tokens: TokenSet) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func load() -> TokenSet? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
