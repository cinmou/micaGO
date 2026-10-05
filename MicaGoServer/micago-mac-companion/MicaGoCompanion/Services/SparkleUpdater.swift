import AppKit
import Combine
import Sparkle

@MainActor
final class SparkleUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @Published var automaticallyDownloadsUpdates = false {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )
    private var observation: NSKeyValueObservation?

    private override init() {
        super.init()
        // Keep the feed owned by the signed app, rather than an old preferences override.
        controller.updater.clearFeedURLFromUserDefaults()
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        controller.startUpdater()
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            await AppModel.shared.refresh()
            await BackendController.shared.resumeAfterAppUpdateIfNeeded(externalReachable: AppModel.shared.reachable)
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        BackendController.shared.prepareForAppUpdate()
    }
}
