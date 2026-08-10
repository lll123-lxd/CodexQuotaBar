import Combine
import Foundation

typealias SnapshotLoader = @Sendable (MonitorTarget, Date) -> CodexSnapshot

@MainActor
final class CodexUsageStore: ObservableObject {
    static let officialRefreshInterval: TimeInterval = 10

    @Published private(set) var monitorSnapshots: [MonitorSnapshot] = []
    @Published private(set) var connectionState: QuotaConnectionState = .logs

    var snapshot: CodexSnapshot {
        monitorSnapshots.first?.snapshot ?? .empty
    }

    private let officialClient: any OfficialRateLimitClient
    private let snapshotLoader: SnapshotLoader
    private let monitorTargets: @Sendable () -> [MonitorTarget]
    private let now: @Sendable () -> Date
    private let refreshQueue = DispatchQueue(label: "codex.quota.refresh", qos: .userInitiated)
    private var latestOfficial: OfficialRateLimits?
    private var latestOfficialAt: Date?
    private var officialReadTask: Task<Void, Never>?
    private var officialPollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var logRefreshTask: Task<Void, Never>?
    private var isLogRefreshing = false
    private var logRefreshPending = false
    private var officialRefreshPending = false
    private var isRunning = false
    private var preferencesObserver: AnyCancellable?

    init(
        officialClient: any OfficialRateLimitClient = CodexAppServerClient(),
        snapshotLoader: @escaping SnapshotLoader = { target, date in
            CodexLogScanner(sessionsRoot: target.sessionsURL, configURL: target.configURL)
                .loadSnapshot(now: date)
        },
        monitorTargets: @escaping @Sendable () -> [MonitorTarget] = {
            AppPreferences.monitorTargets.filter(\.isEnabled)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.officialClient = officialClient
        self.snapshotLoader = snapshotLoader
        self.monitorTargets = monitorTargets
        self.now = now
    }

    func connectionState(for target: MonitorTarget) -> QuotaConnectionState {
        target.id == "default-codex" ? connectionState : .logs
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        preferencesObserver = NotificationCenter.default.publisher(for: AppPreferences.didChangeNotification)
            .sink { [weak self] _ in
                self?.restartLogTimer()
                self?.refreshNow()
            }

        let client = officialClient
        eventTask = Task { [weak self] in
            for await event in client.events {
                guard !Task.isCancelled else { break }
                self?.handle(event)
            }
        }
        refreshNow()
        restartLogTimer()
        restartOfficialPollTimer()
    }

    func stop() {
        isRunning = false
        logRefreshPending = false
        officialRefreshPending = false
        logRefreshTask?.cancel()
        officialPollTask?.cancel()
        officialReadTask?.cancel()
        eventTask?.cancel()
        logRefreshTask = nil
        officialPollTask = nil
        officialReadTask = nil
        eventTask = nil
        preferencesObserver = nil

        let client = officialClient
        Task { await client.stop() }
    }

    func refreshNow() {
        guard isRunning else { return }
        refreshLogs()
        refreshOfficial()
    }

    private func refreshLogs() {
        guard !isLogRefreshing else {
            logRefreshPending = true
            return
        }
        isLogRefreshing = true
        let targets = monitorTargets()
        let scanDate = now()
        let loader = snapshotLoader

        refreshQueue.async { [weak self] in
            let snapshots = targets.map {
                MonitorSnapshot(target: $0, snapshot: loader($0, scanDate))
            }
            Task { @MainActor [weak self] in
                self?.finishLogRefresh(snapshots)
            }
        }
    }

    private func finishLogRefresh(_ snapshots: [MonitorSnapshot]) {
        guard isRunning else {
            isLogRefreshing = false
            logRefreshPending = false
            return
        }
        monitorSnapshots = snapshots.map(applyingLatestOfficial)
        isLogRefreshing = false
        if logRefreshPending {
            logRefreshPending = false
            refreshLogs()
        }
    }

    private func applyingLatestOfficial(to monitor: MonitorSnapshot) -> MonitorSnapshot {
        guard monitor.target.id == "default-codex",
              let latestOfficial,
              let latestOfficialAt else {
            return monitor
        }
        return MonitorSnapshot(
            target: monitor.target,
            snapshot: latestOfficial.applying(to: monitor.snapshot, at: latestOfficialAt)
        )
    }

    private func handle(_ event: CodexAppServerEvent) {
        switch event {
        case let .stateChanged(state):
            connectionState = state
            if case .reconnecting = state, officialReadTask == nil {
                refreshOfficial()
            }
        case .rateLimitsChanged:
            refreshOfficial()
        }
    }

    private func refreshOfficial() {
        guard officialReadTask == nil else {
            officialRefreshPending = true
            return
        }
        let client = officialClient
        officialReadTask = Task { [weak self] in
            defer { self?.finishOfficialRefresh() }
            do {
                let limits = try await client.readRateLimits()
                guard !Task.isCancelled else { return }
                self?.receiveOfficial(limits)
            } catch is CancellationError {
                return
            } catch {
                self?.receiveOfficialFailure(error)
            }
        }
    }

    private func receiveOfficial(_ limits: OfficialRateLimits) {
        let fetchedAt = now()
        latestOfficial = limits
        latestOfficialAt = fetchedAt
        connectionState = .live(updatedAt: fetchedAt)
        monitorSnapshots = monitorSnapshots.map { monitor in
            guard monitor.target.id == "default-codex" else { return monitor }
            return MonitorSnapshot(
                target: monitor.target,
                snapshot: limits.applying(to: monitor.snapshot, at: fetchedAt)
            )
        }
    }

    private func receiveOfficialFailure(_ error: Error) {
        if latestOfficial == nil {
            connectionState = .logs
        } else {
            connectionState = .reconnecting(attempt: 1, message: error.localizedDescription)
        }
    }

    private func finishOfficialRefresh() {
        officialReadTask = nil
        if isRunning && officialRefreshPending {
            officialRefreshPending = false
            refreshOfficial()
        }
    }

    private func restartLogTimer() {
        logRefreshTask?.cancel()
        let interval = AppPreferences.refreshInterval
        logRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self?.refreshLogs()
            }
        }
    }

    private func restartOfficialPollTimer() {
        officialPollTask?.cancel()
        officialPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.officialRefreshInterval * 1_000_000_000)
                )
                guard !Task.isCancelled else { break }
                self?.refreshOfficial()
            }
        }
    }
}
