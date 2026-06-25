import Foundation

/// Real SoundCloud client, implemented against the public OpenAPI spec
/// (github.com/soundcloud/api → openapi/api.yaml).
///
/// All requests carry `Authorization: OAuth <token>`; `SoundCloudAuth` refreshes
/// the token transparently.
final class LiveSoundCloudAPI: SoundCloudAPI {
    private let auth: SoundCloudAuth
    private let session = URLSession.shared

    init(auth: SoundCloudAuth) { self.auth = auth }

    func likedTracks() async throws -> [Track] {
        let dtos = try await getAllTracks(path: "/me/likes/tracks", query: [
            "access": "playable,preview",
            "limit": "200",
            "linked_partitioning": "true"
        ])
        // Everything in the likes list is, by definition, liked.
        return dtos.compactMap { $0.toTrack() }.map {
            var track = $0; track.isLiked = true; return track
        }
    }

    func search(_ query: String) async throws -> [Track] {
        let page: Paged<TrackDTO> = try await get("/tracks", query: [
            "q": query,
            "access": "playable,preview",
            "limit": "50",
            "linked_partitioning": "true"
        ])
        return page.collection.compactMap { $0.toTrack() }
    }

    func playlists() async throws -> [Playlist] {
        let page: Paged<PlaylistDTO> = try await get("/me/playlists", query: [
            "show_tracks": "false",
            "limit": "50",
            "linked_partitioning": "true"
        ])
        return page.collection.compactMap { $0.toPlaylist() }
    }

    func tracks(in playlist: Playlist) async throws -> [Track] {
        let dtos = try await getAllTracks(path: "/playlists/\(playlist.urn)/tracks", query: [
            "access": "playable,preview",
            "limit": "200",
            "linked_partitioning": "true"
        ], cap: 500)
        return dtos.compactMap { $0.toTrack() }
    }

    func relatedTracks(to seed: Track) async throws -> [Track] {
        let page: Paged<TrackDTO> = try await get("/tracks/\(seed.urn)/related", query: [
            "access": "playable,preview",
            "limit": "50",
            "linked_partitioning": "true"
        ])
        return page.collection.compactMap { $0.toTrack() }
    }

    func setLiked(_ liked: Bool, track: Track) async throws {
        try await send(method: liked ? "POST" : "DELETE", path: "/likes/tracks/\(track.urn)")
    }

    func me() async throws -> Account {
        let dto: MeDTO = try await get("/me")
        return dto.toAccount()
    }

    func feed() async throws -> [Track] {
        let items: [FeedItemDTO] = try await getAll(path: "/me/feed/tracks", query: [
            "limit": "200",
            "linked_partitioning": "true"
        ], cap: 400)
        return items
            .filter { ($0.type ?? "").hasPrefix("track") }
            .compactMap { $0.origin?.toTrack() }
    }

    func followings() async throws -> [SCUser] {
        var users: [SCUser] = []
        var page: Paged<UserDTO> = try await get("/me/followings", query: [
            "limit": "200", "linked_partitioning": "true"
        ])
        users.append(contentsOf: page.collection.compactMap { $0.toUser() })
        var requests = 0
        while let next = page.nextHref, let url = URL(string: next), users.count < 3000, requests < 30 {
            requests += 1
            page = try await get(url: url)
            users.append(contentsOf: page.collection.compactMap { $0.toUser() })
        }
        return users
    }

    func likes(of user: SCUser) async throws -> [Track] {
        let dtos = try await getAllTracks(path: "/users/\(user.urn)/likes/tracks", query: [
            "access": "playable,preview",
            "limit": "200",
            "linked_partitioning": "true"
        ], cap: 500)
        return dtos.compactMap { $0.toTrack() }
    }

    func playbackURL(for track: Track) async throws -> URL {
        let streams: StreamsDTO = try await get("/tracks/\(track.urn)/streams")
        guard let resolver = streams.preferredURL else {
            throw AuthError.server("No HLS stream available for \(track.title)")
        }
        return try await resolveSignedURL(resolver)
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await get(url: Self.makeURL(path: path, query: query))
    }

    private func get<T: Decodable>(url: URL) async throws -> T {
        var (data, http) = try await perform(url: url, token: auth.validAccessToken())

        // Token revoked before nominal expiry → refresh once and retry.
        if http.statusCode == 401 {
            (data, http) = try await perform(url: url, token: auth.forceRefresh())
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AuthError.notAuthenticated }
            throw AuthError.server("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Follows `next_href` through all pages (up to `cap` items / 30 requests),
    /// so large collections like a big Likes list come back complete.
    private func getAll<T: Decodable>(path: String, query: [String: String], cap: Int) async throws -> [T] {
        var collected: [T] = []
        var page: Paged<T> = try await get(path, query: query)
        collected.append(contentsOf: page.collection)
        var requests = 0
        while let next = page.nextHref, let url = URL(string: next), collected.count < cap, requests < 30 {
            requests += 1
            page = try await get(url: url)
            collected.append(contentsOf: page.collection)
        }
        return collected
    }

    private func getAllTracks(path: String, query: [String: String], cap: Int = 1000) async throws -> [TrackDTO] {
        try await getAll(path: path, query: query, cap: cap)
    }

    /// Fire-and-confirm request for mutating endpoints (like/unlike), with the
    /// same 401 → refresh → retry as `get`.
    private func send(method: String, path: String) async throws {
        let url = Self.makeURL(path: path, query: [:])
        func once(_ token: String) async throws -> HTTPURLResponse {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthError.server("No HTTP response") }
            return http
        }
        var http = try await once(auth.validAccessToken())
        if http.statusCode == 401 { http = try await once(auth.forceRefresh()) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AuthError.notAuthenticated }
            throw AuthError.server("HTTP \(http.statusCode)")
        }
    }

    private func perform(url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.server("No HTTP response")
        }
        return (data, http)
    }

    /// The `/streams` URL is an authenticated resolver that 302-redirects to a
    /// short-lived signed CDN playlist. We capture that `Location` and hand the
    /// signed URL to AVPlayer so its segment requests need no auth header.
    private func resolveSignedURL(_ url: URL) async throws -> URL {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse,
           let location = http.value(forHTTPHeaderField: "Location"),
           let signed = URL(string: location) {
            return signed
        }
        // Some deployments return JSON `{ "url": "..." }` instead of a redirect.
        if let object = try? JSONDecoder().decode([String: String].self, from: data),
           let resolved = object["url"].flatMap(URL.init(string:)) {
            return resolved
        }
        return url
    }

    private static func makeURL(path: String, query: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.soundcloud.com"
        components.percentEncodedPath = path   // colons in URNs are valid path chars
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }
}

/// Stops `URLSession` from auto-following the 302 so we can read `Location`.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
