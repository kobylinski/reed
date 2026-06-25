import AppKit

/// Top-down coordinate container for stacking history rows.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One self-refreshing view holding the mini-player, the recently-played rows,
/// and the transport toolbar. A timer (running in the menu's tracking run loop)
/// keeps the toolbar's active states and the history rows up to date while the
/// menu stays open — so jumping, skipping, or radio-advancing updates live.
///
/// Height is fixed for the menu session: it reserves a slot per previous track
/// that exists when the menu opens. The common case (playing with history) is
/// fully live; brand-new queues with no history yet only populate on reopen.
final class PlayerPanelView: NSView {
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onShuffleToggle: (() -> Bool)?
    var onRepeatToggle: (() -> Bool)?
    var onRadioToggle: (() -> Bool)?
    var onSelectHistory: ((Int) -> Void)?

    private weak var engine: PlaybackEngine?
    private let miniPlayer: MiniPlayerView
    private let historyContainer = FlippedView()   // top-down, so slot 0 is the top row
    private var nav: NavBarView?
    private let historySlots: Int
    private var lastHistoryKey: [Int] = []
    private var timer: Timer?

    private let miniH: CGFloat = 77
    private let rowH: CGFloat = 32
    private let navH: CGFloat = 30
    private let dividerGap: CGFloat = 6
    private let dividerZone: CGFloat = 13   // 6 above + 1px line + 6 below

    override var isFlipped: Bool { true }

    init(engine: PlaybackEngine) {
        self.engine = engine
        self.miniPlayer = MiniPlayerView(engine: engine)
        let hasNav = engine.current != nil
        self.historySlots = hasNav ? 3 : 0   // fixed 3 rows; skeletons fill the empties
        let height = miniH + (hasNav ? dividerZone + CGFloat(historySlots) * rowH + navH : 0)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        autoresizingMask = [.width]

        miniPlayer.frame = NSRect(x: 0, y: 0, width: 300, height: miniH)
        miniPlayer.onPlayPause = { [weak self] in self?.onPlayPause?() }
        addSubview(miniPlayer)

        guard hasNav else { return }

        // Divider between the player and the history/toolbar, with 6px margins.
        let divider = NSView(frame: NSRect(x: 6, y: miniH + dividerGap, width: 300 - 12, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.autoresizingMask = [.width]
        addSubview(divider)

        let contentTop = miniH + dividerZone
        historyContainer.frame = NSRect(x: 0, y: contentTop, width: 300, height: CGFloat(historySlots) * rowH)
        historyContainer.autoresizingMask = [.width]
        addSubview(historyContainer)

        let navView = NavBarView(shuffleActive: engine.isShuffleEnabled, repeatActive: engine.isRepeatOne,
                                 radioActive: engine.isRadioEnabled, isPlaying: engine.isPlaying)
        navView.frame = NSRect(x: 0, y: contentTop + CGFloat(historySlots) * rowH, width: 300, height: navH)
        navView.autoresizingMask = [.width]
        navView.onPrev = { [weak self] in self?.onPrev?() }
        navView.onNext = { [weak self] in self?.onNext?() }
        navView.onPlayPause = { [weak self] in self?.onPlayPause?() }
        navView.onShuffleToggle = { [weak self] in self?.onShuffleToggle?() ?? false }
        navView.onRepeatToggle = { [weak self] in self?.onRepeatToggle?() ?? false }
        navView.onRadioToggle = { [weak self] in self?.onRadioToggle?() ?? false }
        addSubview(navView)
        nav = navView

        rebuildHistory()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    private func start() {
        stop()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        timer = t
        tick()
    }

    private func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }

    private func tick() {
        guard let engine else { return }
        nav?.setActive(shuffle: engine.isShuffleEnabled, repeatOne: engine.isRepeatOne, radio: engine.isRadioEnabled)
        nav?.setPlaying(engine.isPlaying)
        if engine.previousIndices(historySlots) != lastHistoryKey { rebuildHistory() }
    }

    private func rebuildHistory() {
        guard let engine else { return }
        let indices = engine.previousIndices(historySlots)   // up to 3, most recent first
        lastHistoryKey = indices
        historyContainer.subviews.forEach { $0.removeFromSuperview() }

        for slot in 0..<historySlots {
            let frame = NSRect(x: 0, y: CGFloat(slot) * rowH, width: historyContainer.bounds.width, height: rowH)
            let view: NSView
            if slot < indices.count, engine.queue.indices.contains(indices[slot]) {
                let index = indices[slot]
                let row = HistoryRowView(track: engine.queue[index], engine: engine)
                row.onSelect = { [weak self] in self?.onSelectHistory?(index) }
                view = row
            } else {
                view = SkeletonRowView(frame: frame)   // reserve the slot
            }
            view.frame = frame
            view.autoresizingMask = [.width]
            historyContainer.addSubview(view)
        }
    }
}
