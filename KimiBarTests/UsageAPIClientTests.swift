@testable import KimiBar
import XCTest

final class UsageAPIClientTests: XCTestCase {
    func testFetchUsesAuthenticatedGETAndDecodesBothLimitFormats() async throws {
        var capturedRequest: URLRequest?
        let session = Self.mockSession { request in
            capturedRequest = request
            return Self.response(for: request, json: """
            {
              "usages": {
                "limit_month_total": { "used_ratio": 0.25, "reset_time": 1700000000 },
                "limit_5h": { "used_ratio": "0.8", "reset_time": 1700000100 }
              }
            }
            """)
        }

        let usage = try await UsageAPIClient(session: session).fetchUsage(accessToken: "test-token")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.kimi.ai/coding/v1/usages")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest?.timeoutInterval, 30)
        XCTAssertEqual(usage.monthly?.remainingRatio, 0.75)
        let fiveHour = try XCTUnwrap(usage.fiveHour)
        XCTAssertEqual(fiveHour.remainingRatio, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(usage.monthly?.resetTime, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(usage.fiveHour?.resetTime, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testDecodesISO8601ResetTimes() throws {
        let usage = try UsageAPIClient.decode(Data("""
        {
          "usages": {
            "limit_month_total": { "used_ratio": 0.25, "reset_time": "2026-12-01T00:00:00.123Z" },
            "limit_5h": { "used_ratio": 0.8, "reset_time": "2026-10-30T12:30:33Z" }
          }
        }
        """.utf8))

        XCTAssertEqual(usage.monthly?.resetTime, Date(timeIntervalSince1970: 1_796_083_200.123))
        XCTAssertEqual(usage.fiveHour?.resetTime, Date(timeIntervalSince1970: 1_793_363_433))
    }

    func testMissingLimitAndResetTimeRemainUnavailable() throws {
        let usage = try UsageAPIClient.decode(Data("""
        { "usages": { "limit_month_total": { "used_ratio": "0.4" } } }
        """.utf8))

        XCTAssertNil(usage.fiveHour)
        let monthly = try XCTUnwrap(usage.monthly)
        XCTAssertEqual(monthly.remainingRatio, 0.6, accuracy: 0.000_001)
        XCTAssertNil(monthly.resetTime)
    }

    func testRatioBoundariesProduceRemainingRatio() throws {
        let usage = try UsageAPIClient.decode(Data("""
        {
          "usages": {
            "limit_month_total": { "used_ratio": 0 },
            "limit_5h": { "used_ratio": "1" }
          }
        }
        """.utf8))

        XCTAssertEqual(usage.monthly?.remainingRatio, 1)
        XCTAssertEqual(usage.fiveHour?.remainingRatio, 0)
    }

    func testInvalidRatiosOnlyInvalidateTheirOwnValues() throws {
        let invalidValues = ["-0.01", "1.01", "\"not-a-number\"", "\"NaN\"", "null", "true"]

        for invalidValue in invalidValues {
            let usage = try UsageAPIClient.decode(Data("""
            {
              "usages": {
                "limit_month_total": { "used_ratio": \(invalidValue) },
                "limit_5h": { "used_ratio": 0.5 }
              }
            }
            """.utf8))

            XCTAssertNil(usage.monthly, "Expected \(invalidValue) to be unavailable")
            XCTAssertEqual(usage.fiveHour?.remainingRatio, 0.5)
        }

        let missingRatio = try UsageAPIClient.decode(Data("""
        { "usages": { "limit_month_total": {}, "limit_5h": { "used_ratio": 0.5 } } }
        """.utf8))
        XCTAssertNil(missingRatio.monthly)
        XCTAssertEqual(missingRatio.fiveHour?.remainingRatio, 0.5)
    }

    func testStatusColorThresholdsAndAdjacentValues() {
        XCTAssertEqual(Self.limit(remaining: 1).statusColor, .green)
        XCTAssertEqual(Self.limit(remaining: 0.5).statusColor, .green)
        XCTAssertEqual(Self.limit(remaining: 0.499_999).statusColor, .orange)
        XCTAssertEqual(Self.limit(remaining: 0.2).statusColor, .orange)
        XCTAssertEqual(Self.limit(remaining: 0.199_999).statusColor, .red)
        XCTAssertEqual(Self.limit(remaining: 0).statusColor, .red)
    }

    func testHTTPErrorCarriesRetryAfterSeconds() async {
        let session = Self.mockSession { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            )!
            return (response, Data())
        }

        do {
            _ = try await UsageAPIClient(session: session).fetchUsage(accessToken: "test-token")
            XCTFail("Expected rate-limit response")
        } catch {
            XCTAssertEqual(error as? UsageAPIError, .httpStatus(429, retryAfter: 120))
        }
    }

    func testHTTPErrorConvertsRetryAfterHTTPDateToDelay() async {
        let session = Self.mockSession { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil,
                headerFields: ["Retry-After": "Tue, 14 Nov 2023 22:14:50 GMT"]
            )!
            return (response, Data())
        }
        let client = UsageAPIClient(
            session: session,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        do {
            _ = try await client.fetchUsage(accessToken: "test-token")
            XCTFail("Expected server-error response")
        } catch {
            XCTAssertEqual(error as? UsageAPIError, .httpStatus(503, retryAfter: 90))
        }
    }

    func testErrorsHaveReadableDescriptions() {
        XCTAssertEqual(
            UsageAPIError.malformedResponse.localizedDescription,
            "Kimi returned an invalid usage response. Try again."
        )
        XCTAssertEqual(
            UsageAPIError.httpStatus(500, retryAfter: nil).localizedDescription,
            "Usage update failed (HTTP 500). Try again later."
        )
    }

    func testUnexpectedResponseShapeHasClearMalformedResponseError() {
        let malformedFixtures = [
            "not JSON",
            "{}",
            "{ \"usages\": [] }",
        ]

        for fixture in malformedFixtures {
            XCTAssertThrowsError(try UsageAPIClient.decode(Data(fixture.utf8))) { error in
                XCTAssertEqual(error as? UsageAPIError, .malformedResponse)
            }
        }
    }

    private static func limit(remaining: Double) -> UsageLimit {
        UsageLimit(remainingRatio: remaining, resetTime: nil)
    }

    private static func mockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        TestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}
