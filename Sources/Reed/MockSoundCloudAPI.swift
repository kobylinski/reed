import Foundation

/// No-op data source used before sign-in. The full player only appears once the
/// user is authenticated, so these are never exercised in the UI — they just
/// satisfy the `SoundCloudAPI` seam while disconnected.
struct MockSoundCloudAPI: SoundCloudAPI {
    func likedTracks() async throws -> [Track] { [] }
    func search(_ query: String) async throws -> [Track] { [] }
    func playlists() async throws -> [Playlist] { [] }
    func tracks(in playlist: Playlist) async throws -> [Track] { [] }
    func relatedTracks(to seed: Track) async throws -> [Track] { [] }
    func setLiked(_ liked: Bool, track: Track) async throws {}
    func me() async throws -> Account { throw AuthError.notAuthenticated }
    func feed() async throws -> [Track] { [] }
    func followings() async throws -> [SCUser] { [] }
    func likes(of user: SCUser) async throws -> [Track] { [] }
    func playbackURL(for track: Track) async throws -> URL { track.streamURL }
}
