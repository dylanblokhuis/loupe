import Foundation
import Observation
import Sparkle

/// Sparkle, wrapped so SwiftUI can drive it.
///
/// The feed is the appcast published as an asset on every GitHub release (see
/// `SUFeedURL` in Supporting/Info.plist). Sparkle checks it daily on its own and
/// puts up its own "a new version is available" window; everything here exists
/// so the menu bar and Settings can reach the same updater.
@MainActor
@Observable
final class Updater {
    /// Sparkle refuses overlapping checks, so the menu item dims while one is
    /// already running rather than looking like the click did nothing.
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// Fetch and stage the update ahead of time so that clicking Install is all
    /// that is left. Off unless asked for: it spends bandwidth on connections
    /// that may be metered or tethered.
    var automaticallyDownloadsUpdates: Bool {
        didSet { updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    /// The running build, as `1.2.3 (57)` — the number in brackets is what
    /// Sparkle actually compares against the appcast.
    static var installedVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    init() {
        // `startingUpdater: true` starts the scheduled background checks. Both
        // delegates stay nil: they exist to customise behaviour the defaults
        // already get right for an app that ships one .dmg per release.
        // Held locally as well: until every stored property has a value, Swift
        // will not let the initializer read one back off self.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller

        // Sparkle owns the persisted values; these mirror them so SwiftUI has
        // something observable to bind a Toggle to. Assigning in init does not
        // trigger `didSet`, so this does not write straight back.
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates

        // `canCheckForUpdates` is published through KVO, which Observation does
        // not pick up on its own.
        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
