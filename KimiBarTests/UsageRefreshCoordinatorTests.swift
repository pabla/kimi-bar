@testable import KimiBar
import XCTest

@MainActor
final class UsageRefreshCoordinatorTests: XCTestCase {
    func testStartRestoresCachedSnapshotAndRefreshesImmediately() async {
        let cached = StoredUsageSnapshot(
            usage: Self.snapshot(fiveHour: 0.4, monthly: 0.7),
            fetchedAt: Date(timeIntervalSince1970: 900)
        )
        let store = InMemoryUsageSnapshotStore(stored: cached)
        let fetcher = FakeUsageFetcher(results: [.success(Self.snapshot(fiveHour: 0.5, monthly: 0.8))])
        let clock = DeterministicUsageClock(now: Date(timeIntervalSince1970: 1000))
        let coordinator = UsageRefreshCoordinator(fetcher: fetcher, clock: clock, store: store)

        XCTAssertEqual(coordinator.state.snapshot, cached.usage)
        XCTAssertEqual(coordinator.state.lastSuccessfulUpdate, cached.fetchedAt)
        XCTAssertTrue(coordinator.state.isStale)

        coordinator.start()
        await Self.waitUntil { await fetcher.requestCount == 1 }

        XCTAssertEqual(coordinator.state.snapshot, Self.snapshot(fiveHour: 0.5, monthly: 0.8))
        XCTAssertEqual(coordinator.state.lastSuccessfulUpdate, clock.now())
        XCTAssertFalse(coordinator.state.isStale)
        XCTAssertNil(coordinator.state.error)
        XCTAssertEqual(store.stored?.fetchedAt, clock.now())
        coordinator.stop()
    }

    func testScheduledRefreshRunsEvery300Seconds() async throws {
        let fetcher = FakeUsageFetcher(results: [
            .success(Self.snapshot()),
            .success(Self.snapshot(fiveHour: 0.2, monthly: 0.3)),
        ])
        let clock = DeterministicUsageClock()
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher, clock: clock, store: InMemoryUsageSnapshotStore()
        )
        coordinator.start()
        await Self.waitUntil { await fetcher.requestCount == 1 }

        await clock.advance(by: 299)
        try await Task.yield()
        let countBeforeInterval = await fetcher.requestCount
        XCTAssertEqual(countBeforeInterval, 1)
        await clock.advance(by: 1)
        await Self.waitUntil { await fetcher.requestCount == 2 }
        XCTAssertEqual(coordinator.state.snapshot, Self.snapshot(fiveHour: 0.2, monthly: 0.3))
        coordinator.stop()
    }

    func testManualAndPopoverTriggersCoalesceIntoActiveRequest() async throws {
        let fetcher = FakeUsageFetcher(results: [.success(Self.snapshot())], gateFirstRequest: true)
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher,
            clock: DeterministicUsageClock(),
            store: InMemoryUsageSnapshotStore()
        )
        coordinator.start()
        await Self.waitUntil { await fetcher.requestCount == 1 }

        coordinator.refresh()
        coordinator.refresh()
        coordinator.refresh()
        coordinator.popoverOpened()
        try await Task.yield()
        let coalescedCount = await fetcher.requestCount
        XCTAssertEqual(coalescedCount, 1)
        XCTAssertTrue(coordinator.state.isRefreshing)

        await fetcher.releaseFirstRequest()
        await Self.waitUntil { !coordinator.state.isRefreshing }
        coordinator.popoverOpened()
        try await Task.yield()
        let freshPopoverCount = await fetcher.requestCount
        XCTAssertEqual(freshPopoverCount, 1)
        coordinator.stop()
    }

    func testSystemClockAcceptsHugeDelayWithoutOverflow() async {
        let task = Task { try await SystemUsageRefreshClock().sleep(for: 1e308) }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFailureKeepsLastSnapshotStaleAndNextScheduledCycleRecovers() async throws {
        let original = Self.snapshot(fiveHour: 0.4, monthly: 0.7)
        let recovered = Self.snapshot(fiveHour: 0.6, monthly: 0.9)
        let fetcher = FakeUsageFetcher(results: [
            .success(original),
            .failure(TestError.offline),
            .success(recovered),
        ])
        let clock = DeterministicUsageClock()
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher, clock: clock, store: InMemoryUsageSnapshotStore()
        )
        coordinator.start()
        await Self.waitUntil { await fetcher.requestCount == 1 }
        coordinator.refresh()
        await Self.waitUntil { coordinator.state.isStale }

        XCTAssertEqual(coordinator.state.snapshot, original)
        XCTAssertNotNil(coordinator.state.error)
        let failedCount = await fetcher.requestCount
        XCTAssertEqual(failedCount, 2)
        await clock.advance(by: 299)
        try await Task.yield()
        let countBeforeRecovery = await fetcher.requestCount
        XCTAssertEqual(countBeforeRecovery, 2)
        await clock.advance(by: 1)
        await Self.waitUntil { await fetcher.requestCount == 3 }
        XCTAssertEqual(coordinator.state.snapshot, recovered)
        XCTAssertFalse(coordinator.state.isStale)
        coordinator.stop()
    }

    func testCacheSaveFailureKeepsPreviousSnapshotAndReportsError() async {
        let original = Self.snapshot(fiveHour: 0.4, monthly: 0.7)
        let cached = StoredUsageSnapshot(usage: original, fetchedAt: Date(timeIntervalSince1970: 900))
        let store = InMemoryUsageSnapshotStore(stored: cached)
        store.saveError = TestError.cacheFailed
        let coordinator = UsageRefreshCoordinator(
            fetcher: FakeUsageFetcher(results: [.success(Self.snapshot())]),
            clock: DeterministicUsageClock(),
            store: store
        )

        coordinator.start()
        await Self.waitUntil { coordinator.state.error != nil && !coordinator.state.isRefreshing }

        XCTAssertEqual(coordinator.state.snapshot, original)
        XCTAssertEqual(coordinator.state.lastSuccessfulUpdate, cached.fetchedAt)
        XCTAssertEqual(coordinator.state.error as? TestError, .cacheFailed)
        XCTAssertEqual(store.stored, cached)
        coordinator.stop()
    }

    func testTimeout429And500DoNotCauseImmediateRetries() async throws {
        let errors: [Error] = [
            TestError.timeout,
            UsageAPIError.httpStatus(429, retryAfter: nil),
            UsageAPIError.httpStatus(500, retryAfter: nil),
        ]

        for error in errors {
            let fetcher = FakeUsageFetcher(results: [.failure(error)])
            let coordinator = UsageRefreshCoordinator(
                fetcher: fetcher,
                clock: DeterministicUsageClock(),
                store: InMemoryUsageSnapshotStore()
            )
            coordinator.start()
            await Self.waitUntil { coordinator.state.isStale }
            for _ in 0 ..< 20 {
                try await Task.yield()
            }
            let requestCount = await fetcher.requestCount
            XCTAssertEqual(requestCount, 1)
            XCTAssertNil(coordinator.state.snapshot)
            coordinator.stop()
        }
    }

    func testRetryAfterDefersScheduledPolling() async throws {
        let fetcher = FakeUsageFetcher(results: [
            .failure(UsageAPIError.httpStatus(429, retryAfter: 600)),
            .success(Self.snapshot()),
        ])
        let clock = DeterministicUsageClock()
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher, clock: clock, store: InMemoryUsageSnapshotStore()
        )
        coordinator.start()
        await Self.waitUntil { coordinator.state.isStale }

        await clock.advance(by: 300)
        try await Task.yield()
        let countBeforeRetryAfter = await fetcher.requestCount
        XCTAssertEqual(countBeforeRetryAfter, 1)
        coordinator.refresh()
        coordinator.refresh()
        coordinator.refresh()
        try await Task.yield()
        let blockedTriggerCount = await fetcher.requestCount
        XCTAssertEqual(blockedTriggerCount, 1)
        await clock.advance(by: 300)
        await Self.waitUntil { await fetcher.requestCount == 2 }
        XCTAssertFalse(coordinator.state.isStale)
        coordinator.stop()
    }

    func test401PerformsOneCredentialRefreshAndOneUsageRetry() async {
        let transport = FakeUsageAPITransport()
        let credentials = FakeCredentialManager()
        let fetcher = AuthenticatedUsageFetcher(
            usageAPIClient: transport, credentialManager: credentials
        )
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher,
            clock: DeterministicUsageClock(),
            store: InMemoryUsageSnapshotStore()
        )

        coordinator.start()
        await Self.waitUntil { coordinator.state.lastSuccessfulUpdate != nil }

        let forceRefreshValues = await credentials.forceRefreshValues
        let accessTokens = await transport.accessTokens
        XCTAssertEqual(forceRefreshValues, [false, true])
        XCTAssertEqual(accessTokens, ["initial", "rotated"])
        XCTAssertFalse(coordinator.state.isStale)
        coordinator.stop()
    }

    func testFinalUsage401IsReturnedForSessionClassification() async {
        let fetcher = FakeUsageFetcher(results: [
            .failure(UsageAPIError.httpStatus(401, retryAfter: nil)),
        ])
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher, clock: DeterministicUsageClock(), store: InMemoryUsageSnapshotStore()
        )

        coordinator.start()
        await Self.waitUntil { coordinator.state.isStale }

        XCTAssertEqual(coordinator.state.error as? UsageAPIError, .httpStatus(401, retryAfter: nil))
        coordinator.stop()
    }

    func testSignOutStopsPollingAndSignInCanRestartIt() async throws {
        let fetcher = FakeUsageFetcher(results: [
            .success(Self.snapshot()), .success(Self.snapshot()),
        ])
        let clock = DeterministicUsageClock()
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher, clock: clock, store: InMemoryUsageSnapshotStore()
        )
        coordinator.start()
        await Self.waitUntil { await fetcher.requestCount == 1 }

        coordinator.signedOut()
        XCTAssertNil(coordinator.state.error)
        await clock.advance(by: 300)
        try await Task.yield()
        let signedOutCount = await fetcher.requestCount
        XCTAssertEqual(signedOutCount, 1)

        coordinator.start()
        await Self.waitUntil { await fetcher.requestCount == 2 }
        XCTAssertNil(coordinator.state.error)
        coordinator.stop()
    }

    func testUnavailableLimitDoesNotBlankOtherLimit() async {
        let partial = Self.snapshot(fiveHour: nil, monthly: 0.65)
        let fetcher = FakeUsageFetcher(results: [
            .success(partial), .failure(TestError.offline),
        ])
        let coordinator = UsageRefreshCoordinator(
            fetcher: fetcher,
            clock: DeterministicUsageClock(),
            store: InMemoryUsageSnapshotStore()
        )
        coordinator.start()
        await Self.waitUntil { coordinator.state.lastSuccessfulUpdate != nil }
        XCTAssertNil(coordinator.state.snapshot?.fiveHour)
        XCTAssertEqual(coordinator.state.snapshot?.monthly, partial.monthly)

        coordinator.refresh()
        await Self.waitUntil { coordinator.state.isStale }
        XCTAssertEqual(coordinator.state.snapshot, partial)
        coordinator.stop()
    }

    private static func snapshot(
        fiveHour: Double? = 0.5, monthly: Double? = 0.75
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: fiveHour.map { UsageLimit(remainingRatio: $0, resetTime: nil) },
            monthly: monthly.map { UsageLimit(remainingRatio: $0, resetTime: nil) }
        )
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0 ..< 100 {
            if await condition() {
                return
            }
            try? await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }
}

private enum TestError: Error {
    case offline
    case timeout
    case cacheFailed
}

final class UsageFetchCancellationFlag {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

actor FakeUsageFetcher: UsageFetching {
    private var results: [Result<UsageSnapshot, Error>]
    private let gateFirstRequest: Bool
    private let cancellationFlag: UsageFetchCancellationFlag?
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    init(
        results: [Result<UsageSnapshot, Error>],
        gateFirstRequest: Bool = false,
        cancellationFlag: UsageFetchCancellationFlag? = nil
    ) {
        self.results = results
        self.gateFirstRequest = gateFirstRequest
        self.cancellationFlag = cancellationFlag
    }

    func fetchUsage() async throws -> UsageSnapshot {
        requestCount += 1
        if gateFirstRequest && requestCount == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { firstRequestContinuation = $0 }
            } onCancel: {
                cancellationFlag?.cancel()
            }
        }
        return try results.removeFirst().get()
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}

private actor FakeUsageAPITransport: UsageAPIFetching {
    private(set) var accessTokens: [String] = []

    func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        accessTokens.append(accessToken)
        if accessTokens.count == 1 {
            throw UsageAPIError.httpStatus(401, retryAfter: nil)
        }
        return UsageSnapshot(
            fiveHour: UsageLimit(remainingRatio: 0.5, resetTime: nil),
            monthly: nil
        )
    }
}

private actor FakeCredentialManager: CredentialManaging {
    private(set) var forceRefreshValues: [Bool] = []

    func credentials(forceRefresh: Bool) async throws -> KimiCredentials {
        forceRefreshValues.append(forceRefresh)
        return KimiCredentials(
            accessToken: forceRefresh ? "rotated" : "initial",
            refreshToken: "unused",
            expiresAt: Date(timeIntervalSince1970: 10000),
            expiresIn: 3600
        )
    }
}

final class InMemoryUsageSnapshotStore: UsageSnapshotStoring {
    var stored: StoredUsageSnapshot?
    var saveError: Error?

    init(stored: StoredUsageSnapshot? = nil) {
        self.stored = stored
    }

    func load() throws -> StoredUsageSnapshot? {
        stored
    }

    func save(_ snapshot: StoredUsageSnapshot) throws {
        if let saveError {
            throw saveError
        }
        stored = snapshot
    }
}

final class DeterministicUsageClock: UsageRefreshClock, @unchecked Sendable {
    private struct Sleeper {
        let target: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentDate: Date
    private var sleepers: [UUID: Sleeper] = [:]

    init(now: Date = Date(timeIntervalSince1970: 1000)) {
        currentDate = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(
                        target: currentDate.addingTimeInterval(interval),
                        continuation: continuation
                    )
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        currentDate = currentDate.addingTimeInterval(interval)
        let ready = sleepers.filter { $0.value.target <= currentDate }
        ready.keys.forEach { sleepers.removeValue(forKey: $0) }
        lock.unlock()
        ready.values.forEach { $0.continuation.resume() }
    }
}
