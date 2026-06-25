import Foundation

/// A single playable item. The shape is deliberately small and source-agnostic so
/// the same model serves mock data today and real SoundCloud API tracks later.
struct Track: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let artist: String
    let duration: TimeInterval
    let artworkURL: URL?

    /// SoundCloud URN (e.g. `soundcloud:tracks:123`). Used to resolve the live
    /// stream via `GET /tracks/{urn}/streams`. For mock data this mirrors `id`.
    let urn: String

    /// Whether the signed-in user has liked this track (best-known state).
    var isLiked: Bool = false

    /// Directly-playable URL, when known up front (mock/test data).
    ///
    /// For live SoundCloud this is a placeholder — the real HLS URL is resolved
    /// lazily through `SoundCloudAPI.playbackURL(for:)` because it requires an
    /// authenticated call and yields a short-lived signed CDN URL. The playback
    /// engine never reads this field directly; it always goes through the API.
    let streamURL: URL
}
