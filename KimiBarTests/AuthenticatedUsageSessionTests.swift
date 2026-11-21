import XCTest
@testable import KimiBar

@MainActor
final class AuthenticatedUsageSessionTests: XCTestCase {
    func testMissingCredentialsMovesFromRestoringToSignedOutAndStopsPolling() async throws {
        let (session, fetcher, clock, _) = makeSession(results: [
            .failure(KimiCredentialError.authenticationRequired)
        ])

        session.start()
        await Self.waitUntil { session.state.phase == .signedOut }

        XCTAssertFalse(session.state.canRefresh)
        XCTAssertNil(session.state.authenticationFailureReason)
        XCTAssertEqual(session.state.usageFailureReason, "Authentication required")
        clock.advance(by: 300)
        await Task.yield()
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testSignInSuccessStartsPollingWithOneImmediateRefresh() async throws {
        let manager = FakeSessionAuthenticationManager()
        var openedURLs: [URL] = []
        let (session, fetcher, clock, _) = makeSession(
            results: [
                .failure(KimiCredentialError.authenticationRequired),
                .success(Self.snapshot()),
                .success(Self.snapshot(fiveHour: 0.6, monthly: 0.8))
            ],
            manager: manager,
            openBrowser: { openedURLs.append($0); return true }
        )
        session.start()
        await Self.waitUntil { session.state.phase == .signedOut }

        session.signIn()
        await Self.waitUntil { session.state.phase == .signedIn && !session.state.isRefreshing }

        XCTAssertEqual(session.state.snapshot, Self.snapshot())
        XCTAssertEqual(openedURLs, [manager.authorization.verificationURL])
        var requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 2)
        clock.advance(by: 300)
        await Self.waitUntil { await fetcher.requestCount == 3 && !session.state.isRefreshing }
        requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 3)
        session.signOut()
    }

    func testFinal401KeepsSnapshotStaleAndOffersAuthentication() async throws {
        let cached = StoredUsageSnapshot(usage: Self.snapshot(), fetchedAt: Date(timeIntervalSince1970: 900))
        let (session, fetcher, clock, _) = makeSession(
            results: [.failure(UsageAPIError.httpStatus(401, retryAfter: nil))],
            cached: cached
        )

        session.start()
        await Self.waitUntil { session.state.phase == .failed }

        XCTAssertEqual(session.state.snapshot, cached.usage)
        XCTAssertEqual(session.state.lastSuccessfulUpdate, cached.fetchedAt)
        XCTAssertTrue(session.state.isStale)
        XCTAssertEqual(session.state.authenticationFailureReason, "Authentication required")
        XCTAssertFalse(session.state.canRefresh)
        clock.advance(by: 300)
        await Task.yield()
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testSignOutCancelsInFlightUsageBeforeDeletingCredentials() async throws {
        let cancellation = UsageFetchCancellationFlag()
        let fetcher = FakeUsageFetcher(
            results: [.success(Self.snapshot())],
            gateFirstRequest: true,
            cancellationFlag: cancellation
        )
        let manager = FakeSessionAuthenticationManager()
        var cancelledAtSignOut: Bool?
        manager.onSignOut = { cancelledAtSignOut = cancellation.isCancelled }
        let session = AuthenticatedUsageSession(
            manager: manager,
            fetcher: fetcher,
            store: InMemoryUsageSnapshotStore(),
            clock: DeterministicUsageClock(),
            openBrowser: { _ in true }
        )
        session.start()
        await Self.waitUntil { await fetcher.requestCount == 1 }

        session.signOut()

        XCTAssertEqual(cancelledAtSignOut, true)
        await fetcher.releaseFirstRequest()
    }

    func testSignOutStopsPollingAndPreservesSnapshot() async throws {
        let (session, fetcher, clock, manager) = makeSession(results: [.success(Self.snapshot())])
        session.start()
        await Self.waitUntil { session.state.phase == .signedIn && !session.state.isRefreshing }

        session.signOut()
        await Self.waitUntil { session.state.phase == .signedOut }

        XCTAssertEqual(manager.signOutCount, 1)
        XCTAssertEqual(session.state.snapshot, Self.snapshot())
        XCTAssertTrue(session.state.isStale)
        XCTAssertNil(session.state.authenticationFailureReason)
        clock.advance(by: 300)
        await Task.yield()
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testCancellationClearsSignInCodeWithoutStartingUsage() async throws {
        let manager = FakeSessionAuthenticationManager()
        manager.waitForCompletion = true
        let (session, fetcher, clock, _) = makeSession(
            results: [.failure(KimiCredentialError.authenticationRequired)],
            manager: manager
        )
        session.start()
        await Self.waitUntil { session.state.phase == .signedOut }
        session.signIn()
        await Self.waitUntil { session.state.userCode != nil }

        session.cancelSignIn()

        XCTAssertEqual(session.state.phase, .signedOut)
        XCTAssertNil(session.state.userCode)
        XCTAssertNil(session.state.authenticationFailureReason)
        XCTAssertEqual(manager.signOutCount, 1)
        clock.advance(by: 300)
        for _ in 0..<5 { await Task.yield() }
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testOfflineFailureDuringRestoreAllowsSignOut() async throws {
        let (session, _, _, manager) = makeSession(results: [
            .failure(SessionTestError.offline)
        ])

        session.start()
        await Self.waitUntil { session.state.isStale && !session.state.isRefreshing }

        XCTAssertEqual(session.state.phase, .signedIn)
        XCTAssertTrue(session.state.canRefresh)
        XCTAssertNil(session.state.authenticationFailureReason)
        session.signOut()
        XCTAssertEqual(manager.signOutCount, 1)
    }

    func testOfflineFailureDoesNotChangeSignedInPhase() async throws {
        let (session, _, _, _) = makeSession(results: [
            .success(Self.snapshot()),
            .failure(SessionTestError.offline)
        ])
        session.start()
        await Self.waitUntil { session.state.phase == .signedIn && !session.state.isRefreshing }

        session.refresh()
        await Self.waitUntil { session.state.isStale && !session.state.isRefreshing }

        XCTAssertEqual(session.state.phase, .signedIn)
        XCTAssertEqual(session.state.usageFailureReason, "The network is offline.")
        XCTAssertNil(session.state.authenticationFailureReason)
        session.signOut()
    }

    func testCredentialStorageFailureKeepsSignedInPhaseAndNextPolling() async throws {
        let (session, fetcher, clock, _) = makeSession(results: [
            .success(Self.snapshot()),
            .failure(KimiCredentialError.storageUnavailable),
            .success(Self.snapshot(fiveHour: 0.6, monthly: 0.8))
        ])
        session.start()
        await Self.waitUntil { session.state.phase == .signedIn && !session.state.isRefreshing }

        session.refresh()
        await Self.waitUntil { session.state.usageFailureReason != nil }

        XCTAssertEqual(session.state.phase, .signedIn)
        XCTAssertTrue(session.state.canRefresh)
        XCTAssertEqual(session.state.usageFailureReason, "Credential storage is unavailable. Try again.")
        XCTAssertNil(session.state.authenticationFailureReason)
        clock.advance(by: 300)
        await Self.waitUntil { await fetcher.requestCount == 3 && !session.state.isRefreshing }
        XCTAssertNil(session.state.usageFailureReason)
        session.signOut()
    }

    func testStorageFailureDuringRestoreOffersSignInAndRecovers() async throws {
        let (session, _, _, _) = makeSession(results: [
            .failure(KimiCredentialError.storageUnavailable),
            .success(Self.snapshot())
        ])
        session.start()
        await Self.waitUntil { session.state.phase == .failed }

        XCTAssertEqual(
            session.state.authenticationFailureReason,
            "Credential storage is unavailable. Try again."
        )
        session.signIn()
        await Self.waitUntil { session.state.phase == .signedIn && !session.state.isRefreshing }
        XCTAssertEqual(session.state.snapshot, Self.snapshot())
        session.signOut()
    }

    func testFailedSignInShowsSafeFailureWithoutStartingUsage() async throws {
        let manager = FakeSessionAuthenticationManager()
        manager.completionError = SessionSecretError.failed
        let (session, fetcher, _, _) = makeSession(
            results: [.failure(KimiCredentialError.authenticationRequired)],
            manager: manager
        )
        session.start()
        await Self.waitUntil { session.state.phase == .signedOut }

        session.signIn()
        await Self.waitUntil { session.state.phase == .failed }

        XCTAssertEqual(
            session.state.authenticationFailureReason,
            "Sign-in failed. Check your connection and try again."
        )
        XCTAssertFalse(try XCTUnwrap(session.state.authenticationFailureReason).contains("secret-token"))
        XCTAssertNil(session.state.userCode)
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testCredentialStorageFailureDuringSignInExplainsRealCause() async throws {
        let manager = FakeSessionAuthenticationManager()
        manager.completionError = KimiCredentialError.storageUnavailable
        let (session, _, _, _) = makeSession(
            results: [.failure(KimiCredentialError.authenticationRequired)],
            manager: manager
        )
        session.start()
        await Self.waitUntil { session.state.phase == .signedOut }

        session.signIn()
        await Self.waitUntil { session.state.phase == .failed }

        XCTAssertEqual(
            session.state.authenticationFailureReason,
            "Credential storage is unavailable. Try again."
        )
    }

    func testFailedSignOutKeepsSignedInPhaseAndRestartsPolling() async throws {
        let manager = FakeSessionAuthenticationManager()
        manager.signOutError = SessionTestError.signOutFailed
        let (session, fetcher, _, _) = makeSession(results: [
            .success(Self.snapshot()), .success(Self.snapshot())
        ], manager: manager)
        session.start()
        await Self.waitUntil { session.state.phase == .signedIn && !session.state.isRefreshing }

        session.signOut()
        await Self.waitUntil { session.state.authenticationFailureReason != nil }

        XCTAssertEqual(session.state.phase, .signedIn)
        XCTAssertEqual(session.state.authenticationFailureReason, "Sign-out failed. Try again.")
        await Self.waitUntil { await fetcher.requestCount == 2 && !session.state.isRefreshing }
        manager.signOutError = nil
        session.signOut()
    }

    func testAuthenticationFailureReplacesEarlierSignOutFailure() async throws {
        let manager = FakeSessionAuthenticationManager()
        manager.signOutError = SessionTestError.signOutFailed
        let (session, _, _, _) = makeSession(results: [
            .success(Self.snapshot()),
            .failure(UsageAPIError.httpStatus(401, retryAfter: nil))
        ], manager: manager)
        session.start()
        await Self.waitUntil { session.state.phase == .signedIn && !session.state.isRefreshing }
        session.signOut()
        await Self.waitUntil { session.state.authenticationFailureReason == "Sign-out failed. Try again." }

        session.refresh()
        await Self.waitUntil { session.state.phase == .failed }

        XCTAssertEqual(session.state.authenticationFailureReason, "Authentication required")
    }

    private func makeSession(
        results: [Result<UsageSnapshot, Error>],
        manager: FakeSessionAuthenticationManager = FakeSessionAuthenticationManager(),
        cached: StoredUsageSnapshot? = nil,
        openBrowser: @escaping (URL) -> Bool = { _ in true }
    ) -> (AuthenticatedUsageSession, FakeUsageFetcher, DeterministicUsageClock, FakeSessionAuthenticationManager) {
        let fetcher = FakeUsageFetcher(results: results)
        let clock = DeterministicUsageClock()
        let session = AuthenticatedUsageSession(
            manager: manager,
            fetcher: fetcher,
            store: InMemoryUsageSnapshotStore(stored: cached),
            clock: clock,
            openBrowser: openBrowser
        )
        return (session, fetcher, clock, manager)
    }

    private static func snapshot(fiveHour: Double = 0.5, monthly: Double = 0.75) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageLimit(remainingRatio: fiveHour, resetTime: nil),
            monthly: UsageLimit(remainingRatio: monthly, resetTime: nil)
        )
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }
}

private final class FakeSessionAuthenticationManager: AuthenticationManaging {
    let authorization = KimiDeviceAuthorization(
        userCode: "ABCD-1234",
        deviceCode: "device-code",
        verificationURL: URL(string: "https://www.kimi.ai/device?user_code=ABCD-1234")!,
        expiresAt: Date().addingTimeInterval(600),
        interval: 5
    )
    var completionError: Error?
    var waitForCompletion = false
    var signOutError: Error?
    var onSignOut: (() -> Void)?
    private(set) var signOutCount = 0

    func beginDeviceAuthorization() async throws -> KimiDeviceAuthorization { authorization }

    func completeDeviceAuthorization(_ authorization: KimiDeviceAuthorization) async throws {
        if let completionError { throw completionError }
        if waitForCompletion {
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    func signOut() throws {
        if let signOutError { throw signOutError }
        onSignOut?()
        signOutCount += 1
    }
}

private enum SessionTestError: Error, LocalizedError {
    case offline
    case signOutFailed

    var errorDescription: String? {
        switch self {
        case .offline: "The network is offline."
        case .signOutFailed: "Sign-out failed."
        }
    }
}

private enum SessionSecretError: Error, LocalizedError {
    case failed

    var errorDescription: String? { "Failed with secret-token" }
}
