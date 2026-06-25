import Foundation
import AVFoundation
import MediaPlayer
import AppKit

/// HLS-backed queue player wired into macOS Now Playing
/// (`MPNowPlayingInfoCenter`) and hardware/media keys (`MPRemoteCommandCenter`).
///
/// Uses two AVPlayers so DJ mode can crossfade: the next track is buffered on the
/// idle player and the two volumes are ramped (equal-power) over the overlap.
/// Normal playback simply uses whichever player is currently active.
final class PlaybackEngine: NSObject {
    enum Status { case idle, loading, playing, paused }

    private let players = [AVPlayer(), AVPlayer()]
    private var activeIndex = 0
    private var active: AVPlayer { players[activeIndex] }
    private var inactive: AVPlayer { players[1 - activeIndex] }
    private var timeObservers: [Any?] = [nil, nil]
    private var statusObservation: NSKeyValueObservation?

    /// Bumped on every track change so a slow resolve that finishes after the
    /// user skips ahead is discarded instead of hijacking playback.
    private var generation = 0
    /// Guards against an infinite skip loop when every track fails to load.
    private var consecutiveFailures = 0

    private var artworkTrackID: String?
    private var currentArtwork: MPMediaItemArtwork?
    private var isToppingUp = false

    /// Current track's downloaded artwork, for the in-menu mini-player.
    private(set) var artworkImage: NSImage?

    // DJ crossfade
    private let crossfadeDuration: TimeInterval = 6
    private var isCrossfading = false
    private var crossfadeGen = 0
    private var fadeTimer: Timer?

    private(set) var queue: [Track] = []
    private(set) var index: Int = 0
    private(set) var status: Status = .idle

    /// Radio mode: when the queue runs low it auto-extends with tracks related to
    /// the current song, so playback never stops.
    private(set) var isRadioEnabled = false

    /// DJ mode: equal-power crossfade between consecutive tracks. On by default.
    private(set) var isDJEnabled = true

    /// Async resolver from `Track` to a directly-playable URL. Injected by
    /// AppDelegate so the engine stays decoupled from mock vs. live.
    var resolveStreamURL: ((Track) async throws -> URL)?

    /// Given a seed track, returns related tracks for radio mode.
    var radioProvider: ((Track) async throws -> [Track])?

    /// Fired on any state change the UI should reflect (track/play/pause/load).
    var onStateChange: (() -> Void)?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var isPlaying: Bool { status == .playing }

    // MARK: Progress / seek (drives the mini-player waveform)

    var currentSeconds: Double { let t = active.currentTime().seconds; return t.isFinite ? t : 0 }
    var durationSeconds: Double {
        if let d = active.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
        return current?.duration ?? 0
    }
    var progress: Double { let d = durationSeconds; return d > 0 ? min(1, max(0, currentSeconds / d)) : 0 }

    func seek(toFraction fraction: Double) {
        let d = durationSeconds
        guard d > 0 else { return }
        active.seek(to: CMTime(seconds: d * max(0, min(1, fraction)), preferredTimescale: 600))
        updateNowPlaying()
        onStateChange?()
    }

    // MARK: Like

    private var likedOverrides: [String: Bool] = [:]

    /// Injected by AppDelegate to like/unlike via the API.
    var likeAction: ((_ track: Track, _ liked: Bool) async throws -> Void)?

    func isLiked(_ track: Track) -> Bool { likedOverrides[track.id] ?? track.isLiked }
    var isCurrentLiked: Bool { current.map(isLiked) ?? false }

    func toggleLikeCurrent() { if let track = current { toggleLike(track) } }

    /// Optimistically toggles the like for any track, reverting if the API fails.
    func toggleLike(_ track: Track) {
        let newValue = !isLiked(track)
        likedOverrides[track.id] = newValue
        onStateChange?()
        Task { @MainActor in
            do {
                try await self.likeAction?(track, newValue)
            } catch {
                self.likedOverrides[track.id] = !newValue
                NSLog("Like toggle failed: \(error.localizedDescription)")
                self.onStateChange?()
            }
        }
    }

    override init() {
        super.init()
        configureRemoteCommands()
        for i in 0..<players.count {
            timeObservers[i] = players[i].addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] _ in
                self?.tick(playerIndex: i)
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: nil
        )
    }

    // MARK: Queue control

    /// Replace the queue and start playing at `start`. The "play likes / play
    /// playlist / start from song" entry point.
    func load(_ tracks: [Track], startingAt start: Int = 0) {
        cancelCrossfade()
        queue = tracks
        index = tracks.isEmpty ? 0 : max(0, min(start, tracks.count - 1))
        consecutiveFailures = 0
        persist()
        playCurrent()
    }

    /// Restore a saved queue without auto-playing — ready to resume on demand.
    func restore(_ tracks: [Track], startingAt start: Int) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        status = .paused
        if let track = current { loadArtwork(for: track) }
        updateNowPlaying()
        onStateChange?()
    }

    /// Stop playback and forget the queue (used on logout).
    func clear() {
        cancelCrossfade()
        players.forEach { $0.pause(); $0.replaceCurrentItem(with: nil) }
        queue = []
        index = 0
        status = .idle
        isRadioEnabled = false
        isShuffleEnabled = false
        currentArtwork = nil
        artworkImage = nil
        QueueStore.clear()
        updateNowPlaying()
        onStateChange?()
    }

    func togglePlayPause() {
        if active.currentItem == nil, current != nil { playCurrent(); return }
        isPlaying ? pause() : resume()
    }

    func pause() {
        cancelCrossfade()
        active.pause()
        status = .paused
        updateNowPlaying()
        onStateChange?()
    }

    func resume() {
        guard active.currentItem != nil else { playCurrent(); return }
        active.play()
        status = .playing
        updateNowPlaying()
        onStateChange?()
    }

    func next() {
        guard !queue.isEmpty else { return }
        cancelCrossfade()
        if index + 1 < queue.count {
            index += 1
        } else if isRadioEnabled {
            extendThenAdvance()
            return
        } else {
            index = 0
        }
        persist()
        playCurrent()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        cancelCrossfade()
        index = (index - 1 + queue.count) % queue.count
        persist()
        playCurrent()
    }

    /// Queue positions of the up-to-`n` tracks played just before the current
    /// one, most-recent first (drives the history rows).
    func previousIndices(_ n: Int) -> [Int] {
        guard index > 0 else { return [] }
        return Array((max(0, index - n)..<index).reversed())
    }

    /// Repeat-one: loop the current track instead of advancing.
    private(set) var isRepeatOne = false

    func setRepeatOne(_ on: Bool) { isRepeatOne = on; onStateChange?() }

    /// Shuffle mode: reflected as an "active" state on the shuffle button.
    private(set) var isShuffleEnabled = false

    func setShuffle(_ on: Bool) {
        isShuffleEnabled = on
        if on { shuffleUpcoming() }
        onStateChange?()
    }

    /// Shuffle the upcoming tracks, leaving history and the current track intact.
    func shuffleUpcoming() {
        guard index + 1 < queue.count else { return }
        let head = Array(queue[0...index])
        let tail = Array(queue[(index + 1)...]).shuffled()
        queue = head + tail
        persist()
        onStateChange?()
    }

    /// Jump to a queue position (used by the history rows).
    func play(at position: Int) {
        guard queue.indices.contains(position) else { return }
        cancelCrossfade()
        index = position
        persist()
        playCurrent()
    }

    // MARK: Radio

    func setRadioEnabled(_ on: Bool) {
        isRadioEnabled = on
        onStateChange?()
        if on { topUpIfNeeded() }
    }

    /// "Detach": drop the current playlist context and start an endless radio
    /// seeded by `seed`, continuing the current playback uninterrupted when
    /// `seed` is already playing.
    func startRadio(from seed: Track) {
        isRadioEnabled = true
        let alreadyPlaying = current?.id == seed.id && active.currentItem != nil
        queue = [seed]
        index = 0
        persist()
        if alreadyPlaying {
            onStateChange?()
            topUp(seed: seed)
        } else {
            playCurrent()
        }
    }

    private func extendThenAdvance() {
        guard let seed = current else { return }
        status = .loading
        onStateChange?()
        Task { @MainActor in
            let fresh = self.uniqueNew(try? await self.radioProvider?(seed))
            guard !fresh.isEmpty else {
                self.status = .idle
                self.onStateChange?()
                return
            }
            self.queue.append(contentsOf: fresh)
            self.index += 1
            self.persist()
            self.playCurrent()
        }
    }

    private func topUpIfNeeded() {
        guard isRadioEnabled, let seed = current, index >= queue.count - 2 else { return }
        topUp(seed: seed)
    }

    private func topUp(seed: Track) {
        guard !isToppingUp else { return }
        isToppingUp = true
        Task { @MainActor in
            defer { self.isToppingUp = false }
            let fresh = self.uniqueNew(try? await self.radioProvider?(seed))
            guard !fresh.isEmpty else { return }
            self.queue.append(contentsOf: fresh)
            self.persist()
        }
    }

    private func uniqueNew(_ candidates: [Track]?) -> [Track] {
        let existing = Set(queue.map(\.id))
        var seen = Set<String>()
        return (candidates ?? []).filter { !$0.id.isEmpty && !existing.contains($0.id) && seen.insert($0.id).inserted }
    }

    // MARK: DJ crossfade

    func setDJEnabled(_ on: Bool) {
        isDJEnabled = on
        onStateChange?()
    }

    private func tick(playerIndex: Int) {
        guard playerIndex == activeIndex else { return }  // ignore the fading-out player
        updateNowPlaying()
        maybeStartCrossfade()
    }

    private func maybeStartCrossfade() {
        guard isDJEnabled, !isRepeatOne, !isCrossfading, status == .playing,
              index + 1 < queue.count,
              let item = active.currentItem else { return }
        let duration = item.duration.seconds
        let elapsed = active.currentTime().seconds
        guard duration.isFinite, duration > crossfadeDuration, elapsed.isFinite else { return }
        let remaining = duration - elapsed
        if remaining <= crossfadeDuration && remaining > 0.5 {
            beginCrossfade(overlap: min(crossfadeDuration, remaining))
        }
    }

    private func beginCrossfade(overlap: TimeInterval) {
        let nextIndex = index + 1
        guard nextIndex < queue.count else { return }
        isCrossfading = true
        crossfadeGen += 1
        let gen = crossfadeGen
        let nextTrack = queue[nextIndex]

        Task { @MainActor in
            do {
                let url = try await self.resolveURL(nextTrack)
                guard self.isCrossfading, gen == self.crossfadeGen else { return }
                let item = AVPlayerItem(url: url)
                let incoming = self.inactive
                incoming.replaceCurrentItem(with: item)
                incoming.volume = 0
                incoming.play()
                self.startFade(overlap: overlap, outgoing: self.active, incoming: incoming,
                               toIndex: nextIndex, incomingItem: item)
            } catch {
                NSLog("Crossfade resolve failed: \(error.localizedDescription)")
                self.isCrossfading = false   // fall back to a hard cut at track end
            }
        }
    }

    private func startFade(overlap: TimeInterval, outgoing: AVPlayer, incoming: AVPlayer,
                           toIndex: Int, incomingItem: AVPlayerItem) {
        fadeTimer?.invalidate()
        let stepInterval = 0.05
        let steps = max(1, Int(overlap / stepInterval))
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            guard let self, self.isCrossfading else { timer.invalidate(); return }
            step += 1
            let p = min(1.0, Double(step) / Double(steps))
            outgoing.volume = Float(cos(p * .pi / 2))   // equal-power: constant total energy
            incoming.volume = Float(sin(p * .pi / 2))
            if p >= 1.0 {
                timer.invalidate()
                self.completeCrossfade(outgoing: outgoing, incoming: incoming,
                                       toIndex: toIndex, incomingItem: incomingItem)
            }
        }
    }

    private func completeCrossfade(outgoing: AVPlayer, incoming: AVPlayer,
                                   toIndex: Int, incomingItem: AVPlayerItem) {
        outgoing.pause()
        outgoing.replaceCurrentItem(with: nil)
        outgoing.volume = 1
        activeIndex = players.firstIndex { $0 === incoming } ?? (1 - activeIndex)
        active.volume = 1
        index = toIndex
        isCrossfading = false
        consecutiveFailures = 0
        observeStatus(of: incomingItem)
        persist()
        status = .playing
        loadArtwork(for: queue[index])
        updateNowPlaying()
        onStateChange?()
        topUpIfNeeded()
    }

    private func cancelCrossfade() {
        crossfadeGen += 1
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard isCrossfading else { return }
        inactive.pause()
        inactive.replaceCurrentItem(with: nil)
        inactive.volume = 1
        active.volume = 1
        isCrossfading = false
    }

    // MARK: Playback internals

    private func playCurrent() {
        guard let track = current else { return }
        generation += 1
        let gen = generation
        status = .loading
        onStateChange?()
        loadArtwork(for: track)

        Task { @MainActor in
            do {
                let url = try await self.resolveURL(track)
                guard gen == self.generation else { return }
                self.startPlayback(url: url)
            } catch {
                NSLog("Stream resolve failed for \(track.title): \(error.localizedDescription)")
                self.handlePlaybackFailure()
            }
        }
    }

    private func resolveURL(_ track: Track) async throws -> URL {
        if let resolver = resolveStreamURL { return try await resolver(track) }
        return track.streamURL
    }

    private func startPlayback(url: URL) {
        let item = AVPlayerItem(url: url)
        active.replaceCurrentItem(with: item)
        active.volume = 1
        observeStatus(of: item)
        active.play()
        status = .playing
        updateNowPlaying()
        onStateChange?()
        topUpIfNeeded()
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let itemStatus = item.status
            let error = item.error
            DispatchQueue.main.async {
                guard let self else { return }
                switch itemStatus {
                case .readyToPlay:
                    self.consecutiveFailures = 0
                    if self.status == .loading {
                        self.status = .playing
                        self.onStateChange?()
                    }
                case .failed:
                    NSLog("Playback item failed: \(error?.localizedDescription ?? "unknown")")
                    if !self.isCrossfading { self.handlePlaybackFailure() }
                default:
                    break
                }
            }
        }
    }

    /// Only the active player's current item advances the queue (ignores the
    /// fading-out item and any stale end notifications).
    @objc private func itemDidEnd(_ note: Notification) {
        guard let ended = note.object as? AVPlayerItem,
              ended === active.currentItem, !isCrossfading else { return }
        if isRepeatOne {
            active.seek(to: .zero)
            active.play()
            return
        }
        consecutiveFailures = 0
        next()
    }

    /// Skip a dead track, but stop after a full lap so a broken queue doesn't spin.
    private func handlePlaybackFailure() {
        consecutiveFailures += 1
        guard !queue.isEmpty, consecutiveFailures < queue.count else {
            status = .idle
            consecutiveFailures = 0
            onStateChange?()
            return
        }
        next()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }

    private func loadArtwork(for track: Track) {
        currentArtwork = nil
        artworkImage = nil
        artworkTrackID = track.id
        onStateChange?()   // clear stale art in the mini-player immediately
        guard let url = track.artworkURL else { return }
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data),
                  self.artworkTrackID == track.id else { return }
            self.artworkImage = image
            self.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
            self.onStateChange?()
        }
    }

    private func updateNowPlaying() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            infoCenter.nowPlayingInfo = nil
            return
        }
        let elapsed = active.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? elapsed : 0,
            MPNowPlayingInfoPropertyPlaybackRate: active.rate
        ]
        if track.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = track.duration
        }
        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    private func persist() {
        QueueStore.save(tracks: queue, index: index)
    }
}
