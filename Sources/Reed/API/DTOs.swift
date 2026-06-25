import Foundation

/// `linked_partitioning` envelope returned by collection endpoints.
struct Paged<Item: Decodable>: Decodable {
    let collection: [Item]
    let nextHref: String?
    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

/// Subset of the SoundCloud Track object we actually use.
struct TrackDTO: Decodable {
    let id: Int
    let urn: String?
    let title: String?
    let duration: Int?          // milliseconds, per the OpenAPI spec
    let artworkURL: String?
    let access: String?         // playable | preview | blocked
    let user: UserDTO?
    let userFavorite: Bool?     // set on search/single-track fetches

    struct UserDTO: Decodable { let username: String? }

    enum CodingKeys: String, CodingKey {
        case id, urn, title, duration, access, user
        case artworkURL = "artwork_url"
        case userFavorite = "user_favorite"
    }

    /// Maps to the app model. Returns nil for `blocked` tracks (no streaming).
    func toTrack() -> Track? {
        guard access != "blocked" else { return nil }
        // SoundCloud artwork defaults to 100×100 (`-large`); request 500×500 for
        // a crisp Now Playing thumbnail.
        let artwork = artworkURL?.replacingOccurrences(of: "-large", with: "-t500x500")
        return Track(
            id: String(id),
            title: title ?? "Untitled",
            artist: user?.username ?? "Unknown artist",
            duration: duration.map { TimeInterval($0) / 1000.0 } ?? 0,
            artworkURL: artwork.flatMap(URL.init(string:)),
            urn: urn ?? "soundcloud:tracks:\(id)",
            isLiked: userFavorite ?? false,
            streamURL: URL(string: "about:blank")!   // resolved lazily via /streams
        )
    }
}

/// `GET /me/feed/tracks` item — an activity (`track:post` / `track:repost`)
/// wrapping the actual track in `origin`. `origin` decodes leniently so a
/// non-track activity doesn't fail the whole page.
struct FeedItemDTO: Decodable {
    let type: String?
    let origin: TrackDTO?

    enum CodingKeys: String, CodingKey { case type, origin }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        origin = try? container.decodeIfPresent(TrackDTO.self, forKey: .origin)
    }
}

/// A user object (followings list).
struct UserDTO: Decodable {
    let id: Int?
    let urn: String?
    let username: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, urn, username
        case avatarURL = "avatar_url"
    }

    func toUser() -> SCUser? {
        guard let username, let resolved = urn ?? id.map({ "soundcloud:users:\($0)" }) else { return nil }
        // SoundCloud avatars default to 50px (`-large`); request 200 for the list.
        let avatar = avatarURL?.replacingOccurrences(of: "-large", with: "-t200x200")
        return SCUser(urn: resolved, username: username, avatarURL: avatar.flatMap(URL.init(string:)))
    }
}

/// `GET /me` — the signed-in user.
struct MeDTO: Decodable {
    let username: String?
    let avatarURL: String?
    let permalinkURL: String?

    enum CodingKeys: String, CodingKey {
        case username
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
    }

    func toAccount() -> Account {
        Account(username: username ?? "SoundCloud User",
                avatarURL: avatarURL.flatMap(URL.init(string:)),
                profileURL: permalinkURL.flatMap(URL.init(string:)))
    }
}

/// Subset of the SoundCloud Playlist object used for listing.
struct PlaylistDTO: Decodable {
    let id: Int?
    let urn: String?
    let title: String?
    let trackCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, urn, title
        case trackCount = "track_count"
    }

    func toPlaylist() -> Playlist? {
        guard let title else { return nil }
        guard let resolvedURN = urn ?? id.map({ "soundcloud:playlists:\($0)" }) else { return nil }
        return Playlist(id: resolvedURN, urn: resolvedURN, title: title, trackCount: trackCount ?? 0)
    }
}

/// Response of `GET /tracks/{urn}/streams`.
struct StreamsDTO: Decodable {
    let hlsAac160URL: String?
    let hlsMp3128URL: String?

    enum CodingKeys: String, CodingKey {
        case hlsAac160URL = "hls_aac_160_url"
        case hlsMp3128URL = "hls_mp3_128_url"
    }

    /// Prefer AAC-HLS; fall back to MP3-HLS where AAC isn't available.
    var preferredURL: URL? {
        (hlsAac160URL ?? hlsMp3128URL).flatMap(URL.init(string:))
    }
}
