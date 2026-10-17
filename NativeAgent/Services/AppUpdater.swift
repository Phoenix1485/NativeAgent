import Combine
import Foundation
import Sparkle

enum AppUpdateStatus: Equatable {
    case notChecked, checking, upToDate, available(String), downloading, preparing, installing, cancelled, failed(String)
    var label: String {
        switch self {
        case .notChecked: "Not checked this session"
        case .checking: "Checking for updates…"
        case .upToDate: "You’re up to date"
        case .available(let version): "Update \(version) available"
        case .downloading: "Downloading update…"
        case .preparing: "Verifying and preparing update…"
        case .installing: "Installing update…"
        case .cancelled: "Download cancelled. You can try again."
        case .failed(let message): "Update failed: \(message)"
        }
    }
}

/// Retains Sparkle's standard signed-update UI and mirrors its actual byte callbacks.
@MainActor
final class UpdateProgressDriver: SPUStandardUserDriver {
    weak var owner: AppUpdater?
    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.beginDownload()
        super.showDownloadInitiated(cancellation: cancellation)
    }
    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.expectedDownloadBytes = expectedContentLength
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }
    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.receivedDownloadBytes += length
        super.showDownloadDidReceiveData(ofLength: length)
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var configured = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var status: AppUpdateStatus = .notChecked
    @Published private(set) var lastChecked: Date?
    @Published var expectedDownloadBytes: UInt64 = 0
    @Published var receivedDownloadBytes: UInt64 = 0
    @Published var showWhatsNew = false
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastChecked = defaults.object(forKey: "lastAppUpdateCheck") as? Date
        super.init()
    }
    @Published var automaticallyChecks = true {
        didSet { if configured { sparkle?.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    @Published var automaticallyDownloads = true {
        didSet { if configured { sparkle?.automaticallyDownloadsUpdates = automaticallyDownloads } }
    }
    private var sparkle: SPUUpdater?
    private var progressDriver: UpdateProgressDriver?
    private var deferredInstall: (() -> Void)?
    private var activitySubscription: AnyCancellable?
    weak var model: WorkspaceViewModel?

    static let downloadPageURL = URL(string: "https://phoenix1485.github.io/NativeAgent/")!

    static func versionLabel(info: [String: Any]) -> String {
        let version = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version, !version.isEmpty else { return "Development build" }
        guard let build, !build.isEmpty else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    var installedVersionLabel: String {
        // Preview/test hosts have their own version; never present that as NativeAgent's.
        guard Bundle.main.bundleIdentifier == "dev.nativeagent.mac" else { return "Development build" }
        return Self.versionLabel(info: Bundle.main.infoDictionary ?? [:])
    }

    static func validConfiguration(_ info: [String: Any]) -> Bool {
        guard let raw = info["SUFeedURL"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start(model: WorkspaceViewModel) {
        guard sparkle == nil, Bundle.main.bundleURL.pathExtension == "app",
              Self.validConfiguration(Bundle.main.infoDictionary ?? [:]) else { return }
        self.model = model
        let driver = UpdateProgressDriver(hostBundle: .main, delegate: nil)
        driver.owner = self; progressDriver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        sparkle = updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.sessionInProgress).receive(on: DispatchQueue.main).sink { [weak self] active in
            if active, self?.status != .downloading { self?.status = .checking }
        }.store(in: &subscriptions)
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        configured = true
        // Observe work events rather than polling while a relaunch is postponed.
        activitySubscription = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.resumeDeferredInstallIfIdle() }
        }
        do { try updater.start() }
        catch { configured = false; recordFailure(error); return }
        presentWhatsNew(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        // Sparkle recommends additional checks only immediately after starting its scheduler.
        // Do not add a second polling timer or interfere with wake/scheduled checks.
        if Self.shouldCheckAtLaunch(enabled: automaticallyChecks, lastCheck: updater.lastUpdateCheckDate) {
            updater.checkForUpdatesInBackground()
        }
    }

    static func shouldCheckAtLaunch(enabled: Bool, lastCheck: Date?, now: Date = .now) -> Bool {
        enabled && (lastCheck.map { now.timeIntervalSince($0) >= 900 } ?? true)
    }

    private var subscriptions = Set<AnyCancellable>()
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        status = .checking
        sparkle?.checkForUpdates()
    }
    func recordCheck(at date: Date = .now) {
        lastChecked = date; defaults.set(date, forKey: "lastAppUpdateCheck")
    }
    func presentWhatsNew(build: String?) {
        guard let build, !build.isEmpty, defaults.string(forKey: "whatsNewBuild") != build else { return }
        showWhatsNew = true
    }
    func acknowledgeWhatsNew(build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        if let build { defaults.set(build, forKey: "whatsNewBuild") }
        showWhatsNew = false
    }
    var downloadFraction: Double? {
        guard expectedDownloadBytes > 0 else { return nil }
        return min(1, Double(receivedDownloadBytes) / Double(expectedDownloadBytes))
    }
    func beginDownload() { receivedDownloadBytes = 0; expectedDownloadBytes = 0; status = .downloading }
    func recordFailure(_ error: Error) {
        let error = error as NSError
        status = .failed([error.localizedDescription, error.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: " "))
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        recordCheck(); status = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        recordNoUpdate(error)
    }
    func recordNoUpdate(_ error: Error) {
        availableVersion = nil
        recordCheck()
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if let reason, reason.int32Value == SPUNoUpdateFoundReason.onLatestVersion.rawValue || reason.int32Value == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue {
            status = .upToDate
        } else { recordFailure(error) }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        availableVersion = nil
        status = .installing
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) { beginDownload() }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { status = .preparing }
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) { recordFailure(error) }
    func userDidCancelDownload(_ updater: SPUUpdater) { status = .cancelled }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        recordCheck()
        // A normal no-update cycle also reports SUNoUpdateError after the detailed callback.
        if (error as NSError).domain != SUSparkleErrorDomain || (error as NSError).code != 1001 { recordFailure(error) }
    }

    var installationMustWait: Bool {
        guard let model else { return false }
        return model.isWorking || model.libraryTools.storageBusy || model.accountActionInProgress || model.features.activeTask != nil || model.features.finishingTask
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
