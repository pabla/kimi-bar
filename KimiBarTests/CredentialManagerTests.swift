import XCTest
@testable import KimiBar

final class CredentialManagerTests: XCTestCase {
    private var session: URLSession!
    private var store: FakeCredentialStore!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = FakeCredentialStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        session = URLSession(configuration: configuration)
        TestURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        TestURLProtocol.reset()
        try super.tearDownWithError()
    }

    func testFreshKeychainCredentialsDoNotTriggerOAuth() async throws {
        store.stored = credentials(accessToken: "stored-access")
        let manager = makeManager()
        TestURLProtocol.handler = { _ in
            XCTFail("Fresh credentials must not trigger OAuth")
            throw URLError(.badURL)
        }

        let loaded = try await manager.credentials()

        XCTAssertEqual(loaded, store.stored)
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    func testProactiveRefreshPersistsRotatedPair() async throws {
        store.stored = credentials(
            accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: now.addingTimeInterval(60)
        )
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.kimi.ai/api/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let fields = try XCTUnwrap(self.formFields(request))
            XCTAssertEqual(fields["client_id"], "17e5f671-d194-4dfb-9706-5516cb48c098")
            XCTAssertEqual(fields["grant_type"], "refresh_token")
            XCTAssertEqual(fields["refresh_token"], "old-refresh")
            return try Self.jsonResponse(request: request, body: [
                "access_token": "new-access",
                "refresh_token": "new-refresh",
                "expires_in": "7200"
            ])
        }

        let refreshed = try await manager.credentials()

        XCTAssertEqual(refreshed, credentials(
            accessToken: "new-access", refreshToken: "new-refresh",
            expiresAt: now.addingTimeInterval(7_200), expiresIn: 7_200
        ))
        XCTAssertEqual(store.stored, refreshed)
    }

    func testRefreshWithoutRotatedTokenKeepsCurrentRefreshToken() async throws {
        store.stored = credentials(
            accessToken: "old-access", refreshToken: "current-refresh",
            expiresAt: now.addingTimeInterval(60)
        )
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, body: [
                "access_token": "new-access", "expires_in": 3_600
            ])
        }

        let refreshed = try await manager.credentials()

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "current-refresh")
        XCTAssertEqual(store.stored, refreshed)
    }

    func testForcedRefreshWorksBeforeExpiry() async throws {
        store.stored = credentials()
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, body: [
                "access_token": "forced-access",
                "refresh_token": "forced-refresh",
                "expires_in": 3_600
            ])
        }

        let refreshed = try await manager.credentials(forceRefresh: true)

        XCTAssertEqual(refreshed.accessToken, "forced-access")
        XCTAssertEqual(refreshed.refreshToken, "forced-refresh")
        XCTAssertEqual(TestURLProtocol.requests.count, 1)
        XCTAssertEqual(store.stored, refreshed)
    }

    func testNetworkFailureDuringRefreshDoesNotRequireAuthentication() async {
        store.stored = credentials(expiresAt: now.addingTimeInterval(60))
        let manager = makeManager()
        TestURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await manager.credentials()
            XCTFail("Expected a network error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testServerFailureDuringRefreshDoesNotRequireAuthentication() async throws {
        store.stored = credentials(expiresAt: now.addingTimeInterval(60))
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, status: 500, body: ["error": "server_error"])
        }

        do {
            _ = try await manager.credentials()
            XCTFail("Expected a session-refresh error")
        } catch {
            XCTAssertEqual(error as? KimiOAuthError, .refreshFailed)
        }
    }

    func testEmptyUnauthorizedRefreshResponseRequiresAuthentication() async throws {
        store.stored = credentials(expiresAt: now.addingTimeInterval(60))
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await manager.credentials()
            XCTFail("Expected authentication-required outcome")
        } catch {
            XCTAssertEqual(error as? KimiCredentialError, .authenticationRequired)
        }
    }

    func testUnrecoverableRefreshLeavesKeychainUnchangedAndRedactsSecrets() async throws {
        let original = credentials(
            accessToken: "old-access-secret", refreshToken: "old-refresh-secret",
            expiresAt: now.addingTimeInterval(60)
        )
        store.stored = original
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"error_description\":\"old-refresh-secret\"}".utf8))
        }

        do {
            _ = try await manager.credentials()
            XCTFail("Expected authentication-required outcome")
        } catch {
            XCTAssertEqual(error as? KimiCredentialError, .authenticationRequired)
            XCTAssertFalse(error.localizedDescription.contains("old-refresh-secret"))
        }
        XCTAssertEqual(store.stored, original)
    }

    func testSuccessfulDeviceAuthorizationPollsAndPersistsTokens() async throws {
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            if request.url?.path == "/api/oauth/device_authorization" {
                XCTAssertEqual(try XCTUnwrap(self.formFields(request))["client_id"], "17e5f671-d194-4dfb-9706-5516cb48c098")
                return try Self.jsonResponse(request: request, body: self.deviceResponse())
            }
            let fields = try XCTUnwrap(self.formFields(request))
            XCTAssertEqual(fields["device_code"], "device-code")
            XCTAssertEqual(fields["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
            return try Self.jsonResponse(request: request, body: [
                "access_token": "device-access",
                "refresh_token": "device-refresh",
                "expires_in": 3_600
            ])
        }

        let authorization = try await manager.beginDeviceAuthorization()
        try await manager.completeDeviceAuthorization(authorization)

        XCTAssertEqual(authorization.userCode, "ABCD-1234")
        XCTAssertEqual(authorization.verificationURL.absoluteString, "https://www.kimi.ai/device?user_code=ABCD-1234")
        XCTAssertEqual(store.stored, credentials(
            accessToken: "device-access", refreshToken: "device-refresh",
            expiresAt: now.addingTimeInterval(3_600)
        ))
    }

    func testPendingAndSlowDownPollingUseServerIntervals() async throws {
        var sleeps: [TimeInterval] = []
        let manager = makeManager(sleep: { interval in sleeps.append(interval) })
        let authorization = deviceAuthorization()
        var tokenRequests = 0
        TestURLProtocol.handler = { request in
            tokenRequests += 1
            let error = tokenRequests == 1 ? "authorization_pending" : tokenRequests == 2 ? "slow_down" : nil
            if let error {
                return try Self.jsonResponse(request: request, status: 400, body: ["error": error])
            }
            return try Self.jsonResponse(request: request, body: [
                "access_token": "access", "refresh_token": "refresh", "expires_in": 3_600
            ])
        }

        try await manager.completeDeviceAuthorization(authorization)

        XCTAssertEqual(tokenRequests, 3)
        XCTAssertEqual(sleeps, [5, 10])
        XCTAssertEqual(store.stored?.accessToken, "access")
    }

    func testCancellationStopsDevicePollingWithoutSavingTokens() async throws {
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, status: 400, body: ["error": "authorization_pending"])
        }
        let task = Task {
            try await manager.completeDeviceAuthorization(self.deviceAuthorization(interval: 1e308))
        }
        for _ in 0..<100 where TestURLProtocol.requests.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 1)

        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let count = TestURLProtocol.requests.count
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(TestURLProtocol.requests.count, count)
        XCTAssertNil(store.stored)
    }

    func testDenialAndExpiryStopPolling() async throws {
        for (serverError, expectedError) in [
            ("access_denied", KimiOAuthError.authorizationDenied),
            ("expired_token", KimiOAuthError.deviceCodeExpired)
        ] {
            TestURLProtocol.reset()
            store.stored = nil
            let manager = makeManager()
            TestURLProtocol.handler = { request in
                try Self.jsonResponse(request: request, status: 400, body: ["error": serverError])
            }

            do {
                try await manager.completeDeviceAuthorization(deviceAuthorization())
                XCTFail("Expected device authorization failure")
            } catch {
                XCTAssertEqual(error as? KimiOAuthError, expectedError)
            }
            XCTAssertEqual(TestURLProtocol.requests.count, 1)
            XCTAssertNil(store.stored)
        }
    }

    func testDeviceAuthorizationTimesOutAtItsExpiry() async throws {
        var currentDate = now
        let manager = makeManager(
            now: { currentDate },
            sleep: { interval in currentDate = currentDate.addingTimeInterval(interval) }
        )
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, status: 400, body: ["error": "authorization_pending"])
        }

        do {
            try await manager.completeDeviceAuthorization(deviceAuthorization(expiresIn: 5, interval: 5))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? KimiOAuthError, .authorizationTimedOut)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 1)
        XCTAssertNil(store.stored)
    }

    func testMalformedDeviceAndTokenResponsesAreRejectedWithoutPersistence() async throws {
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, body: ["device_code": "missing-user-code"])
        }
        do {
            _ = try await manager.beginDeviceAuthorization()
            XCTFail("Expected malformed device response")
        } catch {
            XCTAssertEqual(error as? KimiOAuthError, .malformedResponse)
        }

        TestURLProtocol.reset()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, body: [
                "access_token": "access-without-refresh", "expires_in": 3_600
            ])
        }
        do {
            try await manager.completeDeviceAuthorization(deviceAuthorization())
            XCTFail("Expected malformed token response")
        } catch {
            XCTAssertEqual(error as? KimiOAuthError, .malformedResponse)
        }
        XCTAssertNil(store.stored)
    }

    func testPersistedCredentialsSurviveNewManagerAndLogoutDeletesOnlyAppItem() async throws {
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, body: [
                "access_token": "persisted-access", "refresh_token": "persisted-refresh", "expires_in": 3_600
            ])
        }
        try await manager.completeDeviceAuthorization(deviceAuthorization())

        let restoredManager = KimiCredentialManager(store: store, session: session, now: { self.now })
        let restored = try await restoredManager.credentials()
        XCTAssertEqual(restored.accessToken, "persisted-access")
        try restoredManager.signOut()
        XCTAssertNil(store.stored)
        XCTAssertEqual(store.deleteCount, 1)
    }

    func testSignOutDuringCredentialSaveCannotLeaveRefreshedCredentials() async throws {
        store.stored = credentials()
        let manager = makeManager()
        TestURLProtocol.handler = { request in
            try Self.jsonResponse(request: request, body: [
                "access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3_600
            ])
        }
        let saveStarted = expectation(description: "Credential save started")
        let saveGate = DispatchSemaphore(value: 0)
        store.onSave = {
            saveStarted.fulfill()
            saveGate.wait()
        }
        let refreshTask = Task { try await manager.credentials(forceRefresh: true) }
        await fulfillment(of: [saveStarted], timeout: 1)

        refreshTask.cancel()
        let signOutTask = Task { try manager.signOut() }
        try await Task.sleep(nanoseconds: 20_000_000)
        saveGate.signal()
        _ = try await refreshTask.value
        try await signOutTask.value

        XCTAssertNil(store.stored)
    }

    func testCredentialDescriptionIsRedacted() {
        let secretCredentials = credentials(
            accessToken: "access-secret", refreshToken: "refresh-secret"
        )

        XCTAssertFalse(String(describing: secretCredentials).contains("access-secret"))
        XCTAssertFalse(String(reflecting: secretCredentials).contains("refresh-secret"))
    }

    private func makeManager(
        now: (@Sendable () -> Date)? = nil,
        sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) -> KimiCredentialManager {
        if let sleep {
            return KimiCredentialManager(
                store: store, session: session, now: now ?? { self.now }, sleep: sleep
            )
        }
        return KimiCredentialManager(store: store, session: session, now: now ?? { self.now })
    }

    private func credentials(
        accessToken: String = "test-access",
        refreshToken: String = "test-refresh",
        expiresAt: Date? = nil,
        expiresIn: TimeInterval = 3_600
    ) -> KimiCredentials {
        KimiCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt ?? now.addingTimeInterval(7_200),
            expiresIn: expiresIn
        )
    }

    private func deviceAuthorization(
        expiresIn: TimeInterval = 600,
        interval: TimeInterval = 5
    ) -> KimiDeviceAuthorization {
        KimiDeviceAuthorization(
            userCode: "ABCD-1234",
            deviceCode: "device-code",
            verificationURL: URL(string: "https://www.kimi.ai/device?user_code=ABCD-1234")!,
            expiresAt: now.addingTimeInterval(expiresIn),
            interval: interval
        )
    }

    private func deviceResponse() -> [String: Any] {
        [
            "user_code": "ABCD-1234",
            "device_code": "device-code",
            "verification_uri": "https://www.kimi.ai/device",
            "verification_uri_complete": "https://www.kimi.ai/device?user_code=ABCD-1234",
            "expires_in": 600,
            "interval": 5
        ]
    }

    private func formFields(_ request: URLRequest) -> [String: String]? {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 { data.append(contentsOf: buffer[0..<count]) }
                if count <= 0 { break }
            }
            stream.close()
            body = data
        }
        guard let body,
              let query = String(data: body, encoding: .utf8),
              var components = URLComponents(string: "https://placeholder.invalid")
        else { return nil }
        components.percentEncodedQuery = query
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func jsonResponse(
        request: URLRequest, status: Int = 200, body: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, try JSONSerialization.data(withJSONObject: body))
    }
}
