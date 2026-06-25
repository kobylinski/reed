import AppKit

/// Compact SoundCloud-style mini-player embedded as the first item of the status
/// menu. Play/pause overlays the poster; the right column holds title, artist, a
/// small waveform (click to seek), a top-right like heart, and a next button.
/// Driven live from `PlaybackEngine` via a timer that ticks while the menu is open.
final class MiniPlayerView: NSView {
    /// Routes the play/pause tap so an empty player can start a default source.
    var onPlayPause: (() -> Void)?

    private weak var engine: PlaybackEngine?

    private let artwork = NSImageView()
    private let playButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let waveform = WaveformView()
    private let likeButton = NSButton()

    private var timer: Timer?
    private var shownTrackID: String?
    private var hovered = false
    private var trackingAreaRef: NSTrackingArea?

    /// 6px on the sides, ~3px top/bottom (top is the menu's built-in padding).
    private let inset: CGFloat = 6
    private let poster: CGFloat = 74
    private let width: CGFloat = 300

    override var isFlipped: Bool { true }

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 74 + 3))
        autoresizingMask = [.width]
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private func build() {
        artwork.frame = NSRect(x: inset, y: 0, width: poster, height: poster)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 10   // ~match the menu's corner radius
        artwork.layer?.masksToBounds = true
        artwork.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(artwork)

        // Play/pause overlaying the poster, on a translucent disc.
        let p: CGFloat = 30
        playButton.frame = NSRect(x: inset + poster / 2 - p / 2, y: poster / 2 - p / 2, width: p, height: p)
        playButton.isBordered = false
        playButton.bezelStyle = .regularSquare
        playButton.imagePosition = .imageOnly
        playButton.imageScaling = .scaleProportionallyDown
        playButton.wantsLayer = true
        playButton.layer?.cornerRadius = p / 2
        playButton.layer?.backgroundColor = NSColor(white: 0, alpha: 0.38).cgColor
        playButton.contentTintColor = .white
        playButton.target = self
        playButton.action = #selector(tapPlay)
        addSubview(playButton)

        let colX = inset + poster + 10
        let colW = (width - inset) - colX

        configure(titleLabel, frame: NSRect(x: colX, y: 8, width: colW - 24, height: 15),
                  font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor, mask: [.width])
        configure(artistLabel, frame: NSRect(x: colX, y: 26, width: colW, height: 13),
                  font: .systemFont(ofSize: 10), color: .secondaryLabelColor, mask: [.width])

        // The waveform now owns the full freed space (no transport buttons here).
        waveform.frame = NSRect(x: colX, y: 45, width: colW, height: 25)
        waveform.autoresizingMask = [.width]
        waveform.onSeek = { [weak self] fraction in self?.engine?.seek(toFraction: fraction) }
        addSubview(waveform)

        // Pulled ~6px in from the edge so it isn't glued to the margin.
        layoutButton(likeButton, frame: NSRect(x: width - inset - 18 - 6, y: 5, width: 18, height: 18),
                     symbol: "suit.heart", point: 13, action: #selector(tapLike), mask: [.minXMargin])
    }

    private func configure(_ field: NSTextField, frame: NSRect, font: NSFont, color: NSColor,
                           mask: NSView.AutoresizingMask) {
        field.frame = frame
        field.autoresizingMask = mask
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        addSubview(field)
    }

    private func layoutButton(_ button: NSButton, frame: NSRect, symbol: String, point: CGFloat,
                              action: Selector, mask: NSView.AutoresizingMask) {
        button.frame = frame
        button.autoresizingMask = mask
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = symbolImage(symbol, point: point)
        button.target = self
        button.action = action
        button.contentTintColor = .labelColor
        addSubview(button)
    }

    private func symbolImage(_ name: String, point: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: point, weight: .medium))
    }

    // MARK: Live updates

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stopTimer() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }

    private func refresh() {
        guard let engine else { return }
        let track = engine.current
        let hasTrack = track != nil

        titleLabel.stringValue = track?.title ?? "Nothing playing"
        artistLabel.stringValue = track?.artist ?? ""
        artwork.image = engine.artworkImage ?? Self.placeholder

        if shownTrackID != track?.id {
            shownTrackID = track?.id
            waveform.bars = hasTrack ? Self.bars(for: track?.id ?? "") : []
        }
        waveform.progress = engine.progress

        _ = hasTrack
        playButton.image = LucideIcons.image(engine.isPlaying ? LucideIcons.pause : LucideIcons.play, size: 14)
        playButton.isHidden = !hovered   // show play/pause on hover (even when empty → starts Likes)

        let liked = engine.isCurrentLiked
        likeButton.image = LucideIcons.image(LucideIcons.heart, size: 14, filled: liked)
        likeButton.contentTintColor = liked ? .systemRed : .labelColor

        likeButton.isEnabled = hasTrack
    }

    // MARK: Actions

    @objc private func tapPlay() {
        if let onPlayPause { onPlayPause() } else { engine?.togglePlayPause() }
        refresh()
    }
    @objc private func tapLike() { engine?.toggleLikeCurrent(); refresh() }

    // MARK: Helpers

    private static let placeholder = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)

    /// Deterministic pseudo-waveform so each track has a stable, distinct shape.
    private static func bars(for id: String, count: Int = 40) -> [CGFloat] {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return (0..<count).map { i in
            hash = (hash ^ UInt64(i &+ 1)) &* 1099511628211
            let r = Double((hash >> 33) & 0xFFFF) / 65535.0
            let envelope = 0.35 + 0.65 * sin(Double(i) / Double(max(1, count - 1)) * .pi)
            return CGFloat(min(1.0, max(0.16, envelope * (0.55 + 0.5 * r))))
        }
    }
}

/// SoundCloud-style waveform: played bars in orange, the rest grey. Click to seek.
final class WaveformView: NSView {
    var bars: [CGFloat] = [] { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?

    private let played = NSColor(srgbRed: 1.0, green: 0.333, blue: 0.0, alpha: 1.0)   // #ff5500
    private let unplayed = NSColor(white: 0.55, alpha: 0.40)

    override func draw(_ dirtyRect: NSRect) {
        guard !bars.isEmpty else { return }
        let gap: CGFloat = 1.5
        let barWidth = (bounds.width - CGFloat(bars.count - 1) * gap) / CGFloat(bars.count)
        let midY = bounds.midY
        for (i, height) in bars.enumerated() {
            let barHeight = max(2, height * bounds.height)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = NSRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            let isPlayed = Double(i) / Double(bars.count) <= progress
            (isPlayed ? played : unplayed).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onSeek?(Double(max(0, min(1, point.x / bounds.width))))
    }
}
