import Foundation

/// Persists the current queue so the app reopens where you left off.
/// Stored as plain JSON under Application Support (no secrets — just track metadata).
enum QueueStore {
    struct Saved: Codable {
        let tracks: [Track]
        let index: Int
    }

    private static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-queue.json")
    }

    static func save(tracks: [Track], index: Int) {
        guard !tracks.isEmpty,
              let data = try? JSONEncoder().encode(Saved(tracks: tracks, index: index)) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    static func load() -> Saved? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
