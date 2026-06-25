import Foundation

/// Stand-in data source used before sign-in (or when no credentials are set up).
///
/// The `streamURL`s point at public HLS test assets so the playback engine,
/// Now Playing integration, and media keys can be exercised end-to-end without
/// authentication.
struct MockSoundCloudAPI: SoundCloudAPI {
    func likedTracks() async throws -> [Track] {
        Self.sampleTracks
    }

    func search(_ query: String) async throws -> [Track] {
        guard !query.isEmpty else { return Self.sampleTracks }
        return Self.sampleTracks.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    func playlists() async throws -> [Playlist] {
        [Playlist(id: "mock-pl", urn: "mock-pl", title: "Demo Playlist", trackCount: Self.sampleTracks.count)]
    }

    func tracks(in playlist: Playlist) async throws -> [Track] {
        Self.sampleTracks
    }

    func relatedTracks(to seed: Track) async throws -> [Track] {
        Self.sampleTracks.filter { $0.id != seed.id }
    }

    func setLiked(_ liked: Bool, track: Track) async throws { /* no-op in demo mode */ }

    func me() async throws -> Account {
        Account(username: "Demo User", avatarURL: nil, profileURL: URL(string: "https://soundcloud.com"))
    }

    func feed() async throws -> [Track] { Self.sampleTracks }

    func followings() async throws -> [SCUser] {
        [SCUser(urn: "u1", username: "Demo Friend", avatarURL: nil),
         SCUser(urn: "u2", username: "Another Artist", avatarURL: nil)]
    }

    func likes(of user: SCUser) async throws -> [Track] { Self.sampleTracks }

    func playbackURL(for track: Track) async throws -> URL {
        track.streamURL
    }

    static let sampleTracks: [Track] = [
        track("mock-1", "Advanced Stream (BipBop)", "Apple HLS Sample",
              "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"),
        track("mock-2", "Basic 4x3 Stream", "Apple HLS Sample",
              "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"),
        track("mock-3", "Mux Test Stream", "Mux",
              "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
    ]

    private static func track(_ id: String, _ title: String, _ artist: String, _ url: String) -> Track {
        Track(id: id, title: title, artist: artist, duration: 0,
              artworkURL: nil, urn: id, streamURL: URL(string: url)!)
    }
}
