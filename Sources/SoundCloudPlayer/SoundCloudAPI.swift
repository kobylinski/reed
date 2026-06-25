import Foundation

/// The signed-in user's profile, for the account header.
struct Account {
    let username: String
    let avatarURL: URL?
    let profileURL: URL?
}

/// A SoundCloud user (for the Following list).
struct SCUser: Equatable {
    let urn: String
    let username: String
    let avatarURL: URL?
}

/// The single seam between the app and its data source.
///
/// Everything above this protocol (playback engine, menu bar, future command
/// palette) is written against `Track` and never knows whether the data is
/// mocked or live. `MockSoundCloudAPI` and `LiveSoundCloudAPI` both satisfy it;
/// AppDelegate swaps the concrete instance on login/logout.
protocol SoundCloudAPI {
    /// The signed-in user's liked tracks, newest first.
    func likedTracks() async throws -> [Track]

    /// Global / library search.
    func search(_ query: String) async throws -> [Track]

    /// The signed-in user's playlists (sets), without their tracks.
    func playlists() async throws -> [Playlist]

    /// The playable tracks inside a playlist, in order.
    func tracks(in playlist: Playlist) async throws -> [Track]

    /// SoundCloud's related/recommended tracks for a seed — powers radio mode.
    func relatedTracks(to seed: Track) async throws -> [Track]

    /// Like (`true`) or unlike (`false`) a track for the signed-in user.
    func setLiked(_ liked: Bool, track: Track) async throws

    /// The signed-in user's profile (avatar, username, profile URL).
    func me() async throws -> Account

    /// The user's feed/stream tracks.
    func feed() async throws -> [Track]

    /// Users the signed-in user follows.
    func followings() async throws -> [SCUser]

    /// A specific user's liked tracks.
    func likes(of user: SCUser) async throws -> [Track]

    /// Resolve a directly-playable URL for `track`, immediately before playback.
    ///
    /// Mock returns the track's embedded URL; live calls `/tracks/{urn}/streams`
    /// and follows the redirect to a signed HLS playlist.
    func playbackURL(for track: Track) async throws -> URL
}
