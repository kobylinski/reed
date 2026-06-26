import AppKit

/// Menu-bar shell. No dock icon, no main window — a status item with transport
/// controls, "Play Likes", and SoundCloud sign-in. The active `SoundCloudAPI`
/// swaps between mock and live depending on auth state.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let engine = PlaybackEngine()

    private var auth = SoundCloudAuth()          // nil until credentials.json exists
    private var api: SoundCloudAPI = MockSoundCloudAPI()
    private var playlists: [Playlist] = []
    private var account: Account?
    private var source: PlaySource = .none
    private var followings: [SCUser] = []

    private enum PlaySource: Equatable { case none, likes, playlist(Playlist), feed, user(SCUser) }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Receive the OAuth callback (reed://callback?code=…). The
        // Apple Event handler is the reliable path for custom URL schemes;
        // `application(_:open:)` below is a belt-and-suspenders backup.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C),   // 'GURL' (kInternetEventClass)
            andEventID: AEEventID(0x4755524C)          // 'GURL' (kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue,  // '----' (keyDirectObject)
              let url = URL(string: string) else { return }
        auth?.handleRedirect(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "reed" {
            auth?.handleRedirect(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let auth, auth.isAuthenticated {
            api = LiveSoundCloudAPI(auth: auth)
        }
        engine.resolveStreamURL = { [weak self] track in
            guard let self else { return track.streamURL }
            return try await self.api.playbackURL(for: track)
        }
        engine.radioProvider = { [weak self] seed in
            guard let self else { return [] }
            return try await self.api.relatedTracks(to: seed)
        }
        engine.likeAction = { [weak self] track, liked in
            guard let self else { return }
            try await self.api.setLiked(liked, track: track)
        }

        menu.delegate = self
        menu.autoenablesItems = false   // honor our explicit isEnabled flags
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = LucideIcons.image(LucideIcons.audioLines, size: 16, lineWidth: 2.2)
        statusItem.menu = menu

        // Reopen where we left off (paused, ready to resume).
        if let saved = QueueStore.load() {
            engine.restore(saved.tracks, startingAt: saved.index)
        }
        refreshPlaylists()
        refreshAccount()
        refreshFollowing()
    }

    /// Loads the signed-in user's playlists for the submenu.
    private func refreshPlaylists() {
        guard isLive else { playlists = []; return }
        Task { @MainActor in
            do { playlists = try await api.playlists() }
            catch {
                playlists = []
                NSLog("Failed to load playlists: \(error.localizedDescription)")
            }
        }
    }

    private func refreshAccount() {
        guard isLive else { account = nil; return }
        Task { @MainActor in account = try? await api.me() }
    }

    private func refreshFollowing() {
        guard isLive else { followings = []; return }
        Task { @MainActor in followings = (try? await api.followings()) ?? [] }
    }

    private var isLive: Bool { auth?.isAuthenticated == true }

    /// Rebuilt each time the menu opens so it reflects current state; the
    /// mini-player then updates itself live while the menu stays open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Not signed in → minimal menu: connect / log in, then quit. Nothing else.
        guard isLive else {
            if auth == nil {
                menu.addItem(item("Connect SoundCloud…", #selector(connectSoundCloud), ""))
            } else {
                menu.addItem(item("Log in to SoundCloud…", #selector(login), ""))
            }
            menu.addItem(.separator())
            menu.addItem(item("Quit", #selector(quit), "q"))
            return
        }

        // Signed in → full player.
        let panelItem = NSMenuItem()
        let panel = PlayerPanelView(engine: engine)
        panel.onPrev = { [weak self] in self?.engine.previous() }
        panel.onNext = { [weak self] in self?.engine.next() }
        panel.onPlayPause = { [weak self] in self?.playOrResume() }
        panel.onShuffleToggle = { [weak self] in self?.toggleShuffleMode() ?? false }
        panel.onRepeatToggle = { [weak self] in self?.toggleRepeatMode() ?? false }
        panel.onRadioToggle = { [weak self] in self?.toggleRadioMode() ?? false }
        panel.onSelectHistory = { [weak self] index in self?.engine.play(at: index) }  // menu stays open; panel updates live
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())

        // Play mode — Likes / Playlist / Feed / Following, checkmark only.
        let likesItem = item("Likes", #selector(playLikes), "")
        likesItem.state = (source == .likes) ? .on : .off
        menu.addItem(likesItem)
        menu.addItem(playlistModeItem())
        let feedItem = item("Feed", #selector(playFeed), "")
        feedItem.state = (source == .feed) ? .on : .off
        menu.addItem(feedItem)
        menu.addItem(followingModeItem())
        menu.addItem(.separator())

        // Account.
        if let account {
            let accountItem = NSMenuItem()
            let view = AccountView(account: account)
            view.onLogout = { [weak self] in self?.logout(); self?.menu.cancelTracking() }
            accountItem.view = view
            menu.addItem(accountItem)
        } else {
            menu.addItem(item("Log out of SoundCloud", #selector(logout), ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q"))
    }

    /// "Playlist" with a submenu to choose one; the active playlist's name is
    /// shown beneath the label in a smaller font.
    private func playlistModeItem() -> NSMenuItem {
        let parent = NSMenuItem()
        let title = NSMutableAttributedString(
            string: "Playlist",
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if case .playlist(let active) = source {
            title.append(NSAttributedString(string: "\n" + active.title, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            parent.state = .on
        }
        parent.attributedTitle = title

        let submenu = NSMenu()
        if playlists.isEmpty {
            let placeholder = NSMenuItem(title: isLive ? "No playlists" : "Sign in to see playlists", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
        } else {
            let items = playlists.map {
                ScrollListView.Item(title: $0.trackCount > 0 ? "\($0.title)  (\($0.trackCount))" : $0.title,
                                    imageURL: nil, payload: $0)
            }
            let list = ScrollListView(items: items)
            list.onSelect = { [weak self] item in
                if let playlist = item.payload as? Playlist { self?.startPlaylist(playlist) }
            }
            let listItem = NSMenuItem()
            listItem.view = list
            submenu.addItem(listItem)
        }
        parent.submenu = submenu
        return parent
    }

    /// "Following" with a submenu of the people you follow; selecting one plays
    /// their likes. The active user's name shows beneath the label.
    private func followingModeItem() -> NSMenuItem {
        let parent = NSMenuItem()
        let title = NSMutableAttributedString(
            string: "Following",
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if case .user(let active) = source {
            title.append(NSAttributedString(string: "\n" + active.username, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            parent.state = .on
        }
        parent.attributedTitle = title

        let submenu = NSMenu()
        if followings.isEmpty {
            let placeholder = NSMenuItem(title: isLive ? "Loading…" : "Sign in to see who you follow", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
        } else {
            let items = followings.map { ScrollListView.Item(title: $0.username, imageURL: $0.avatarURL, payload: $0) }
            let list = ScrollListView(items: items, imageCornerRadius: 12)
            list.onSelect = { [weak self] item in
                if let user = item.payload as? SCUser { self?.playUserLikes(user) }
            }
            let listItem = NSMenuItem()
            listItem.view = list
            submenu.addItem(listItem)
        }
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    // MARK: Transport

    @objc private func togglePlay() { engine.togglePlayPause() }
    @objc private func next() { engine.next() }
    @objc private func prev() { engine.previous() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Branch toggle: off → start radio from current; on → return to Likes.
    private func toggleRadioMode() -> Bool {
        if engine.isRadioEnabled {
            engine.setRadioEnabled(false)
            playLikes()
            return false
        }
        startRadioFromCurrent()
        return engine.isRadioEnabled
    }

    /// Repeat-one toggle: loop the current track.
    private func toggleRepeatMode() -> Bool {
        engine.setRepeatOne(!engine.isRepeatOne)
        return engine.isRepeatOne
    }

    /// Shuffle toggle: off → shuffle upcoming; on → return to Likes.
    private func toggleShuffleMode() -> Bool {
        if engine.isShuffleEnabled {
            engine.setShuffle(false)
            playLikes()
            return false
        }
        engine.setShuffle(true)
        return true
    }

    @objc private func startRadioFromCurrent() {
        guard let track = engine.current else {
            return alert("Play a track first, then start radio from it.")
        }
        engine.startRadio(from: track)
    }


    private func startPlaylist(_ playlist: Playlist) {
        Task { @MainActor in
            do {
                let tracks = try await api.tracks(in: playlist)
                guard !tracks.isEmpty else {
                    return alert("“\(playlist.title)” has no playable tracks.")
                }
                engine.setRadioEnabled(false)
                engine.setShuffle(false)
                source = .playlist(playlist)
                engine.load(tracks)
            } catch {
                handleAPIError(error)
            }
        }
    }

    /// Default play: resume/toggle if something's loaded, otherwise start Likes.
    private func playOrResume() {
        if engine.current == nil { playLikes() } else { engine.togglePlayPause() }
    }

    @objc private func playFeed() {
        Task { @MainActor in
            do {
                let tracks = try await api.feed()
                guard !tracks.isEmpty else { return alert("Your feed has no playable tracks.") }
                engine.setRadioEnabled(false)
                engine.setShuffle(false)
                source = .feed
                engine.load(tracks)
            } catch {
                handleAPIError(error)
            }
        }
    }

    private func playUserLikes(_ user: SCUser) {
        Task { @MainActor in
            do {
                let tracks = try await api.likes(of: user)
                guard !tracks.isEmpty else { return alert("\(user.username) has no playable likes.") }
                engine.setRadioEnabled(false)
                engine.setShuffle(false)
                source = .user(user)
                engine.load(tracks)
            } catch {
                handleAPIError(error)
            }
        }
    }

    @objc private func playLikes() {
        Task { @MainActor in
            do {
                let likes = try await api.likedTracks()
                guard !likes.isEmpty else { return alert("No liked tracks found.") }
                engine.setRadioEnabled(false)
                engine.setShuffle(false)
                source = .likes
                engine.load(likes)
            } catch {
                handleAPIError(error)
            }
        }
    }

    // MARK: Auth

    /// One-click setup: register an app on the user's account (no Node, no manual
    /// JSON), then guide them through the one unavoidable portal step.
    @objc private func connectSoundCloud() {
        menu.cancelTracking()
        Task { @MainActor in
            do {
                let credentials = try await Registration.register(
                    name: "Reed", description: "Personal menu-bar player", website: "https://example.com")
                try AppCredentials.save(credentials)
                auth = SoundCloudAuth()   // pick up the new credentials

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Registration.appRedirectURI, forType: .string)
                NSWorkspace.shared.open(URL(string: "https://soundcloud.com/you/apps")!)
                alert("""
                Your app is registered. ✓  One last step (SoundCloud requires it):

                1. I opened your SoundCloud apps page and copied the redirect URI to your clipboard.
                2. Open your app there, paste \(Registration.appRedirectURI) into Redirect URI, and Save.
                3. Back here, click “Log in to SoundCloud.”
                """)
            } catch {
                alert("Couldn’t connect: \(error.localizedDescription)\n\nNote: registering an app requires a SoundCloud Artist Pro subscription.")
            }
        }
    }

    @objc private func login() {
        if auth == nil { auth = SoundCloudAuth() }   // pick up a credentials.json created after launch
        guard let auth else {
            alert(AuthError.missingCredentials.localizedDescription)
            return
        }
        Task { @MainActor in
            do {
                try await auth.login()
                api = LiveSoundCloudAPI(auth: auth)
                refreshPlaylists()
                refreshAccount()
                refreshFollowing()
            } catch {
                alert(error.localizedDescription)
            }
        }
    }

    @objc private func logout() {
        auth?.logout()
        api = MockSoundCloudAPI()
        account = nil
        source = .none
        followings = []
        engine.clear()        // switch the player off; history/toolbar disappear
        refreshPlaylists()
    }

    /// An expired/revoked session degrades to logged-out instead of erroring on
    /// every action; other errors just surface.
    private func handleAPIError(_ error: Error) {
        if case AuthError.notAuthenticated = error {
            auth?.logout()
            api = MockSoundCloudAPI()
            playlists = []
            alert("Your SoundCloud session expired. Please log in again.")
        } else {
            alert(error.localizedDescription)
        }
    }

    private func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSAlert()
        panel.messageText = "Reed"
        panel.informativeText = message
        panel.runModal()
    }
}
