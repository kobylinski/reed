import Foundation

/// A SoundCloud playlist (set). Listed cheaply without its tracks; the tracks
/// are fetched on demand via `SoundCloudAPI.tracks(in:)` when the user plays it.
struct Playlist: Identifiable, Equatable {
    let id: String       // same as urn
    let urn: String
    let title: String
    let trackCount: Int
}
