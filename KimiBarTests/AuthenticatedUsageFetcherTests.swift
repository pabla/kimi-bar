@testable import KimiBar
import XCTest

final class AuthenticatedUsageFetcherTests: XCTestCase {
    private var store: FakeCredentialStore!
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = FakeCredentialStore()
        store.stored = KimiCredentials(
            accessToken: "initial-access",
            refreshToken: "initial-refresh",
            expiresAt: Date().addingTimeInterval(7200),
            expiresIn: 3600
        )

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

    func testUsage401ForcesOneRefreshAndRetriesWithRotatedAccessToken() async throws {
        var usageTokens: [String] = []
        TestURLProtocol.handler = { request in
            if request.url?.host == "api.kimi.ai" {
                usageTokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                if usageTokens.count == 1 {
                    return try Self.response(request: request, status: 401, json: "{}")
                }
                return try Self.response(request: request, status: 200, json: """
                { "usages": { "limit_month_total": { "used_ratio": 0.25 } } }
                """)
            }
            return try Self.response(request: request, status: 200, json: """
            { "access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_in": 3600 }
            """)
        }

        let usage = try await makeFetcher().fetchUsage()

        XCTAssertEqual(usageTokens, ["Bearer initial-access", "Bearer rotated-access"])
        XCTAssertEqual(usage.monthly?.remainingRatio, 0.75)
        XCTAssertEqual(TestURLProtocol.requests.filter { $0.url?.host == "auth.kimi.ai" }.count, 1)
    }

    func testFailedForcedRefreshDoesNotRetryUsage() async throws {
        TestURLProtocol.handler = { request in
            if request.url?.host == "api.kimi.ai" {
                return try Self.response(request: request, status: 401, json: "{}")
            }
            return try Self.response(request: request, status: 401, json: "{\"error\":\"invalid_grant\"}")
        }

        do {
            _ = try await makeFetcher().fetchUsage()
            XCTFail("Expected authentication-required outcome")
        } catch {
            XCTAssertEqual(error as? KimiCredentialError, .authenticationRequired)
        }
        XCTAssertEqual(TestURLProtocol.requests.filter { $0.url?.host == "api.kimi.ai" }.count, 1)
        XCTAssertEqual(TestURLProtocol.requests.filter { $0.url?.host == "auth.kimi.ai" }.count, 1)
    }

    func testSecondUsage401IsReturnedWithoutAnotherRefreshOrRetry() async throws {
        TestURLProtocol.handler = { request in
            if request.url?.host == "api.kimi.ai" {
                return try Self.response(request: request, status: 401, json: "{}")
            }
            return try Self.response(request: request, status: 200, json: """
            { "access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_in": 3600 }
            """)
        }

        do {
            _ = try await makeFetcher().fetchUsage()
            XCTFail("Expected the retry's 401 to be returned")
        } catch {
            XCTAssertEqual(error as? UsageAPIError, .httpStatus(401, retryAfter: nil))
        }
        XCTAssertEqual(TestURLProtocol.requests.filter { $0.url?.host == "api.kimi.ai" }.count, 2)
        XCTAssertEqual(TestURLProtocol.requests.filter { $0.url?.host == "auth.kimi.ai" }.count, 1)
    }

    private func makeFetcher() -> AuthenticatedUsageFetcher {
        AuthenticatedUsageFetcher(
            usageAPIClient: UsageAPIClient(session: session),
            credentialManager: KimiCredentialManager(store: store, session: session)
        )
    }

    private static func response(
        request: URLRequest, status: Int, json: String
    ) throws -> (HTTPURLResponse, Data) {
        let response = try HTTPURLResponse(
            url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}
