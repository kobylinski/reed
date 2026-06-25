import AppKit

/// Standard left indent of a menu item's text, so our custom rows line up with
/// normal items.
private let menuTextInset: CGFloat = 14
/// Side margin for hover highlights, matching the player's margins / menu items.
private let highlightInset: CGFloat = 6
/// SoundCloud orange, used for "active" toggle state.
private let accentColor = NSColor(srgbRed: 1.0, green: 0.333, blue: 0.0, alpha: 1.0)

/// An icon button that mimics a menu item's hover highlight and supports an
/// "active" (accent-tinted) state for toggles. The icon stays a fixed size and
/// centered regardless of the button's size.
final class HoverIconButton: NSView {
    var onClick: (() -> Void)?
    var isActive = false { didSet { updateHighlight() } }

    private let imageView = NSImageView()
    private var hovered = false { didSet { updateHighlight() } }
    private var trackingAreaRef: NSTrackingArea?

    init(image: NSImage, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown   // never upscale → icon stays crisp
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageView.frame = bounds   // fill; scaling keeps the glyph centered at native size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { onClick?() }

    func setImage(_ image: NSImage) { imageView.image = image }

    private func updateHighlight() {
        layer?.backgroundColor = hovered ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        imageView.contentTintColor = hovered ? .white : (isActive ? accentColor : .secondaryLabelColor)
    }
}

/// Horizontal transport toolbar — prev · shuffle · branch · next — spread to fill
/// the full width within the side margins. Shuffle and branch are toggles.
final class NavBarView: NSView {
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onShuffleToggle: (() -> Bool)?   // performs the toggle, returns new active state
    var onRepeatToggle: (() -> Bool)?
    var onRadioToggle: (() -> Bool)?

    private var buttons: [HoverIconButton] = []
    private var playPauseButton: HoverIconButton!

    override var isFlipped: Bool { true }

    init(shuffleActive: Bool, repeatActive: Bool, radioActive: Bool, isPlaying: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        autoresizingMask = [.width]

        let prev = HoverIconButton(image: LucideIcons.image(LucideIcons.stepBack, size: 16), frame: .zero)
        prev.onClick = { [weak self] in self?.onPrev?() }

        playPauseButton = HoverIconButton(image: LucideIcons.image(isPlaying ? LucideIcons.pause : LucideIcons.play, size: 16), frame: .zero)
        playPauseButton.onClick = { [weak self] in self?.onPlayPause?() }

        let next = HoverIconButton(image: LucideIcons.image(LucideIcons.stepForward, size: 16), frame: .zero)
        next.onClick = { [weak self] in self?.onNext?() }

        let shuffle = HoverIconButton(image: LucideIcons.image(LucideIcons.shuffle, size: 16), frame: .zero)
        shuffle.isActive = shuffleActive
        shuffle.onClick = { [weak shuffle, weak self] in shuffle?.isActive = self?.onShuffleToggle?() ?? false }

        let repeatButton = HoverIconButton(image: LucideIcons.image(LucideIcons.repeatIcon, size: 16), frame: .zero)
        repeatButton.isActive = repeatActive
        repeatButton.onClick = { [weak repeatButton, weak self] in repeatButton?.isActive = self?.onRepeatToggle?() ?? false }

        let branch = HoverIconButton(image: LucideIcons.image(LucideIcons.split, size: 16), frame: .zero)
        branch.isActive = radioActive
        branch.onClick = { [weak branch, weak self] in branch?.isActive = self?.onRadioToggle?() ?? false }

        buttons = [prev, playPauseButton, next, shuffle, repeatButton, branch]
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let bw = (bounds.width - highlightInset * 2) / CGFloat(buttons.count)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: highlightInset + CGFloat(i) * bw, y: 2, width: bw, height: bounds.height - 4)
        }
    }

    func setPlaying(_ playing: Bool) {
        playPauseButton.setImage(LucideIcons.image(playing ? LucideIcons.pause : LucideIcons.play, size: 16))
    }

    /// Live-update the toggle states (shuffle = 3, repeat = 4, branch = 5).
    func setActive(shuffle: Bool, repeatOne: Bool, radio: Bool) {
        guard buttons.count == 6 else { return }
        buttons[3].isActive = shuffle
        buttons[4].isActive = repeatOne
        buttons[5].isActive = radio
    }
}

/// Column width matching the 4-button toolbar, so the logout button can sit in
/// the last quarter aligned with the "next" button above.
func toolbarColumnWidth(_ totalWidth: CGFloat) -> CGFloat {
    (totalWidth - highlightInset * 2) / 4
}
func toolbarColumnX(_ index: Int, totalWidth: CGFloat) -> CGFloat {
    highlightInset + CGFloat(index) * toolbarColumnWidth(totalWidth)
}

/// A recently-played track row: small poster + title/artist, a like heart, and a
/// full-row menu-style hover (inset to the side margins). Deliberately dim so it
/// sits behind the player. Clicking the row (but the heart) selects it.
final class HistoryRowView: NSView {
    var onSelect: (() -> Void)?

    private let poster = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let likeButton = NSButton()

    private let track: Track
    private weak var engine: PlaybackEngine?
    private var hovered = false { didSet { needsDisplay = true; applyHoverColors() } }
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(track: Track, engine: PlaybackEngine) {
        self.track = track
        self.engine = engine
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        autoresizingMask = [.width]
        build()
        loadArtwork()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        poster.frame = NSRect(x: menuTextInset, y: 4, width: 24, height: 24)
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true
        poster.layer?.cornerRadius = 6
        poster.layer?.masksToBounds = true
        poster.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        poster.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        addSubview(poster)

        let textX = menuTextInset + 32
        label(titleLabel, frame: NSRect(x: textX, y: 4, width: 196, height: 12),
              font: .systemFont(ofSize: 10.5, weight: .regular))
        label(artistLabel, frame: NSRect(x: textX, y: 17, width: 196, height: 11),
              font: .systemFont(ofSize: 9.5, weight: .regular))
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artist

        // Heart pulled in from the edge so the hover highlight has margin around it.
        likeButton.frame = NSRect(x: 300 - highlightInset - 16 - 6, y: 8, width: 16, height: 16)
        likeButton.autoresizingMask = [.minXMargin]
        likeButton.isBordered = false
        likeButton.bezelStyle = .regularSquare
        likeButton.imagePosition = .imageOnly
        likeButton.imageScaling = .scaleProportionallyDown
        likeButton.target = self
        likeButton.action = #selector(tapLike)
        addSubview(likeButton)

        applyHoverColors()
        refreshLike()
    }

    private func label(_ field: NSTextField, frame: NSRect, font: NSFont) {
        field.frame = frame
        field.autoresizingMask = [.width]
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        addSubview(field)
    }

    private func applyHoverColors() {
        titleLabel.textColor = hovered ? .white : .secondaryLabelColor
        artistLabel.textColor = hovered ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor
        refreshLike()
    }

    private func refreshLike() {
        let liked = engine?.isLiked(track) ?? false
        likeButton.image = LucideIcons.image(LucideIcons.heart, size: 13, filled: liked)
        // On hover the whole row highlights, so the heart goes white like the toolbar icons.
        if hovered {
            likeButton.contentTintColor = .white
        } else {
            likeButton.contentTintColor = liked ? .systemRed : .tertiaryLabelColor
        }
    }

    @objc private func tapLike() { engine?.toggleLike(track); refreshLike() }

    private func loadArtwork() {
        guard let url = track.artworkURL else { return }
        Task { @MainActor in
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                self.poster.image = image
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        let rect = bounds.insetBy(dx: highlightInset, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if likeButton.frame.contains(local) { return likeButton }
        return bounds.contains(local) ? self : nil
    }

    override func mouseUp(with event: NSEvent) { onSelect?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// A shimmering placeholder used to keep the history area a fixed 3-row height
/// so it can update live (an NSMenu can't grow a custom view mid-open).
final class SkeletonRowView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        block(NSRect(x: menuTextInset, y: 4, width: 24, height: 24), radius: 6)
        block(NSRect(x: menuTextInset + 32, y: 8, width: 130, height: 8), radius: 4)
        block(NSRect(x: menuTextInset + 32, y: 20, width: 84, height: 7), radius: 3.5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func block(_ frame: NSRect, radius: CGFloat) {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor   // ~5% darker than bg
        addSubview(view)
    }
}

/// Signed-in account header: avatar + username on the left (3/4), a Lucide logout
/// button in the last quarter aligned with the toolbar's "next" button above.
final class AccountView: NSView {
    var onLogout: (() -> Void)?

    private let avatar = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let logoutButton = HoverIconButton(image: LucideIcons.image(LucideIcons.logOut, size: 16), frame: .zero)

    override var isFlipped: Bool { true }

    init(account: Account) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        autoresizingMask = [.width]

        avatar.frame = NSRect(x: menuTextInset, y: 6, width: 32, height: 32)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 16
        avatar.layer?.masksToBounds = true
        avatar.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        avatar.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        addSubview(avatar)

        nameLabel.stringValue = account.username
        nameLabel.frame = NSRect(x: menuTextInset + 42, y: 14, width: 150, height: 16)
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.autoresizingMask = [.width]
        addSubview(nameLabel)

        logoutButton.onClick = { [weak self] in self?.onLogout?() }
        addSubview(logoutButton)

        loadAvatar(account.avatarURL)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let columnWidth = toolbarColumnWidth(bounds.width)
        logoutButton.frame = NSRect(x: toolbarColumnX(3, totalWidth: bounds.width),
                                    y: (bounds.height - 26) / 2, width: columnWidth, height: 26)
    }

    private func loadAvatar(_ url: URL?) {
        guard let url else { return }
        Task { @MainActor in
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                self.avatar.image = image
            }
        }
    }
}
