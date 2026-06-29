import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` — the modern (macOS 13+) way to
/// register the app itself as a login item, no helper bundle required. The
/// login item points at wherever the app currently lives, so this works best
/// once Reed is in /Applications (where Homebrew installs it).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister Reed as a login item. Returns whether it succeeded.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                break   // already in the desired state
            case (true, _):
                try SMAppService.mainApp.register()
            case (false, _):
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Login item update failed: \(error.localizedDescription)")
            return false
        }
    }
}
