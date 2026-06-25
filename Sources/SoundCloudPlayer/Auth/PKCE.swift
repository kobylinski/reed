import Foundation
import CryptoKit

/// OAuth 2.1 PKCE helpers. SoundCloud requires `code_challenge_method=S256`.
enum PKCE {
    /// 43–128 char high-entropy verifier (base64url of 64 random bytes ≈ 86 chars).
    static func generateVerifier() -> String {
        base64URL(randomBytes(64))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Opaque value echoed back on the redirect to defend against CSRF.
    static func randomState() -> String {
        base64URL(randomBytes(16))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
