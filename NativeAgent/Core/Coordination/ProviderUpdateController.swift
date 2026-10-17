import AppKit
import Combine

enum ProviderModelRefresh: Equatable, Sendable {
    case refreshed(Int), deferred, unavailable(String), failed(String)
    var message: String {
        switch self {
        case .refreshed(let count): "Refreshed \(count) models from the connected ChatGPT account."
        case .deferred: "Model refresh queued until the current work or connection finishes."
        case .unavailable(let message), .failed(let message): message
        }
    }
}

@MainActor
final class ProviderUpdateController: ObservableObject {
    @Published private(set) var results: [CLIUpdateResult] = []
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var nextCheck: Date?
    @Published private(set) var modelMessage = "Connect ChatGPT to refresh its account model catalog."
    @Published var automaticallyChecks: Bool {
        didSet {
            defaults.set(automaticallyChecks, forKey: "providerUpdates.automatic")
            guard started else { return }
            schedule()
            if automaticallyChecks { checkNow() }
        }
    }
    private let defaults: UserDefaults
    private let service: ProviderUpdateService
    private let paths: @MainActor () -> [CheckedCLI: String]
    private let refreshModels: @MainActor () async -> ProviderModelRefresh
    private let now: () -> Date
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var pendingModels = false
    private var lastAttempt: Date?

    init(defaults: UserDefaults = .standard, service: ProviderUpdateService = .init(), now: @escaping () -> Date = Date.init,
         paths: @escaping @MainActor () -> [CheckedCLI: String], refreshModels: @escaping @MainActor () async -> ProviderModelRefresh) {
        self.defaults = defaults; self.service = service; self.paths = paths; self.refreshModels = refreshModels; self.now = now
        automaticallyChecks = defaults.object(forKey: "providerUpdates.automatic") as? Bool ?? true
        lastChecked = defaults.object(forKey: "providerUpdates.lastCheck") as? Date
        if let data = defaults.data(forKey: "providerUpdates.results"), data.count <= 32_768,
           let saved = try? JSONDecoder().decode([CLIUpdateResult].self, from: data) { results = saved.filter { CheckedCLI.allCases.contains($0.cli) } }
    }

    convenience init(model: WorkspaceViewModel, defaults: UserDefaults) {
        self.init(defaults: defaults, paths: { [weak model] in
            guard let model else { return [:] }
            return Dictionary(uniqueKeysWithValues: CheckedCLI.allCases.compactMap { cli in
                guard let path = ProviderExecutable.resolve(cli.provider, configured: model.settings.profile(cli.provider).binaryPath),
                      FileManager.default.isExecutableFile(atPath: path) else { return nil }
                return (cli, path)
            })
        }, refreshModels: { [weak model] in await model?.refreshModelsForUpdateCheck() ?? .unavailable("Workspace closed.") })
        model.objectWillChange.debounce(for: .milliseconds(250), scheduler: RunLoop.main).sink { [weak self] in self?.refreshDeferredModels() }.store(in: &subscriptions)
    }

    deinit { timer?.invalidate(); task?.cancel(); modelTask?.cancel() }
    func start() {
        guard !started, !stopped else { return }
        started = true
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.clockOrWakeChanged() }.store(in: &subscriptions)
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.clockOrWakeChanged() }.store(in: &subscriptions)
        }
        schedule()
        if automaticallyChecks { checkNow() }
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard started, !stopped, automaticallyChecks else { nextCheck = nil; return }
        let date = HalfHourUpdateSchedule.next(after: now())
        nextCheck = date
        let timer = Timer(timeInterval: max(0.001, date.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.scheduledCheck() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func scheduledCheck() {
        guard started, !stopped, automaticallyChecks else { return }
        // A wake notification and the expired timer may arrive together: coalesce that slot.
        let slot = HalfHourUpdateSchedule.latest(at: now())
        if lastAttempt.map({ $0 < slot }) ?? true { checkNow() }
        schedule()
    }
    func clockOrWakeChanged() {
        guard started, !stopped, automaticallyChecks else { return }
        if let attempt = lastAttempt, attempt > now() { lastAttempt = nil }
        scheduledCheck()
    }
    func checkNow() {
        guard !stopped, !checking else { return }
        modelTask?.cancel(); modelTask = nil; pendingModels = false
        checking = true
        let date = now(); lastAttempt = date
        let selectedPaths = paths(), service = service
        task = Task { [weak self] in
            do {
                async let claude = service.check(.claude, path: selectedPaths[.claude], at: date)
                async let grok = service.check(.grok, path: selectedPaths[.grok], at: date)
                let values = try await [claude, grok]
                try Task.checkCancellation()
                guard let self, !self.stopped else { return }
                self.results = values
                self.lastChecked = self.now()
                self.defaults.set(self.lastChecked, forKey: "providerUpdates.lastCheck")
                if let data = try? JSONEncoder().encode(values) { self.defaults.set(data, forKey: "providerUpdates.results") }
                let refresh = await self.refreshModels()
                try Task.checkCancellation()
                self.apply(refresh)
            } catch is CancellationError {} catch { self?.modelMessage = error.localizedDescription }
            self?.checking = false; self?.task = nil
        }
    }
    private func apply(_ result: ProviderModelRefresh) {
        modelMessage = result.message; pendingModels = result == .deferred
    }
    func refreshDeferredModels() {
        guard !stopped, pendingModels, !checking, modelTask == nil else { return }
        modelTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.refreshModels()
            guard !Task.isCancelled, !self.stopped else { return }
            self.apply(result); self.modelTask = nil
        }
    }
    func waitForCheck() async { await task?.value; await modelTask?.value }
    func shutdown() async {
        stopped = true; timer?.invalidate(); timer = nil; nextCheck = nil
        subscriptions.removeAll(); task?.cancel(); modelTask?.cancel()
        await task?.value; await modelTask?.value
        task = nil; modelTask = nil; checking = false
    }
}
