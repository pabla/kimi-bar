import Foundation

protocol UsageRefreshClock: Sendable {
    func now() -> Date
    func sleep(for interval: TimeInterval) async throws
}

struct SystemUsageRefreshClock: UsageRefreshClock {
    func now() -> Date { Date() }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(min(interval, 86_400) * 1_000_000_000))
    }
}

struct UsageRefreshState {
    var snapshot: UsageSnapshot?
    var lastSuccessfulUpdate: Date?
    var isRefreshing: Bool
    var isStale: Bool
    var error: Error?
}

@MainActor
final class UsageRefreshCoordinator {
    private static let pollingInterval: TimeInterval = 300

    private(set) var state: UsageRefreshState
    var onChange: (() -> Void)?

    private let fetcher: any UsageFetching
    private let clock: any UsageRefreshClock
    private let store: any UsageSnapshotStoring
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var notBefore: Date?

    init(
        fetcher: any UsageFetching,
        clock: any UsageRefreshClock = SystemUsageRefreshClock(),
        store: any UsageSnapshotStoring
    ) {
        self.fetcher = fetcher
        self.clock = clock
        self.store = store
        let cached = try? store.load()
        state = UsageRefreshState(
            snapshot: cached?.usage,
            lastSuccessfulUpdate: cached?.fetchedAt,
            isRefreshing: false,
            isStale: cached != nil,
            error: nil
        )
    }

    func start() {
        guard pollingTask == nil else { return }
        refresh()
        pollingTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                let delay = self?.nextPollingDelay() ?? Self.pollingInterval
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                if let notBefore = self.notBefore, notBefore > clock.now() { continue }
                self.refresh()
            }
        }
    }

    func stop() {
        let wasRefreshing = state.isRefreshing
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        notBefore = nil
        state.isRefreshing = false
        if wasRefreshing { onChange?() }
    }

    func refresh() {
        guard refreshTask == nil else { return }
        if let notBefore, notBefore > clock.now() { return }
        notBefore = nil
        state.isRefreshing = true
        onChange?()
        refreshTask = Task { [weak self, fetcher, store, clock] in
            do {
                let snapshot = try await fetcher.fetchUsage()
                guard !Task.isCancelled, let self else { return }
                let stored = StoredUsageSnapshot(usage: snapshot, fetchedAt: clock.now())
                try store.save(stored)
                self.state.snapshot = snapshot
                self.state.lastSuccessfulUpdate = stored.fetchedAt
                self.state.isRefreshing = false
                self.state.isStale = false
                self.state.error = nil
                self.refreshTask = nil
                self.onChange?()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.state.isRefreshing = false
                self.state.isStale = true
                self.state.error = error
                if case UsageAPIError.httpStatus(_, retryAfter: let delay?) = error, delay > 0 {
                    self.notBefore = clock.now().addingTimeInterval(delay)
                }
                self.refreshTask = nil
                self.onChange?()
            }
        }
    }

    func signedOut() {
        stop()
        state.isStale = true
        state.error = nil
        onChange?()
    }

    func popoverOpened() {
        if let lastSuccessfulUpdate = state.lastSuccessfulUpdate,
           clock.now().timeIntervalSince(lastSuccessfulUpdate) < Self.pollingInterval {
            return
        }
        refresh()
    }

    private func nextPollingDelay() -> TimeInterval {
        guard let notBefore else { return Self.pollingInterval }
        return max(Self.pollingInterval, notBefore.timeIntervalSince(clock.now()))
    }
}
