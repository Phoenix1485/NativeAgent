import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var configured = false
    @Published var automaticallyChecks = true {
        didSet { if configured { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    @Published var automaticallyDownloads = true {
        didSet { if configured { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloads } }
    }
    private var controller: SPUStandardUpdaterController?
    private var deferredInstall: (() -> Void)?
    private var activitySubscription: AnyCancellable?
    weak var model: WorkspaceViewModel?

    static func validConfiguration(_ info: [String: Any]) -> Bool {
        guard let raw = info["SUFeedURL"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start(model: WorkspaceViewModel) {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
              Self.validConfiguration(Bundle.main.infoDictionary ?? [:]) else { return }
        self.model = model
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        configured = true
        // Observe work events rather than polling while a relaunch is postponed.
        activitySubscription = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.resumeDeferredInstallIfIdle() }
        }
        controller.startUpdater()
        // Sparkle recommends additional checks only immediately after starting its scheduler.
        // Do not add a second polling timer or interfere with wake/scheduled checks.
        if Self.shouldCheckAtLaunch(enabled: automaticallyChecks, lastCheck: controller.updater.lastUpdateCheckDate) {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    static func shouldCheckAtLaunch(enabled: Bool, lastCheck: Date?, now: Date = .now) -> Bool {
        enabled && (lastCheck.map { now.timeIntervalSince($0) >= 900 } ?? true)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var installationMustWait: Bool {
        guard let model else { return false }
        return model.isWorking || model.accountActionInProgress || model.features.activeTask != nil || model.features.finishingTask
            || model.features.editorHasChanges || model.features.fileSaveInProgress || model.features.importingFiles || !model.features.mcp.connecting.isEmpty
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard installationMustWait else { return false }
        deferredInstall = installHandler
        return true
    }

    private func resumeDeferredInstallIfIdle() {
        guard !installationMustWait, let install = deferredInstall else { return }
        deferredInstall = nil
        install()
    }
}
