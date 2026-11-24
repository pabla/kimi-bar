import Foundation

struct UsageSnapshot: Equatable, Codable {
    let fiveHour: UsageLimit?
    let monthly: UsageLimit?
}

struct UsageLimit: Equatable, Codable {
    let remainingRatio: Double
    let resetTime: Date?

    var statusColor: UsageBarColor {
        if remainingRatio >= 0.5 {
            return .green
        }
        if remainingRatio >= 0.2 {
            return .orange
        }
        return .red
    }
}

enum UsageAPIError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int, retryAfter: TimeInterval?)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .malformedResponse:
            "Kimi returned an invalid usage response. Try again."
        case .httpStatus(let status, retryAfter: _):
            "Usage update failed (HTTP \(status)). Try again later."
        }
    }
}

protocol UsageAPIFetching {
    func fetchUsage(accessToken: String) async throws -> UsageSnapshot
}

struct UsageAPIClient: UsageAPIFetching {
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.kimi.ai/coding/v1/usages")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UsageAPIError.invalidResponse
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw UsageAPIError.httpStatus(
                response.statusCode,
                retryAfter: Self.retryAfter(from: response, now: now())
            )
        }
        return try Self.decode(data)
    }

    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if let delay = TimeInterval(value), delay.isFinite, delay >= 0 {
            return delay
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    static func decode(_ data: Data) throws -> UsageSnapshot {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let response = try decoder.decode(RawUsageResponse.self, from: data)
            return UsageSnapshot(
                fiveHour: response.usages.limit5h?.limit,
                monthly: response.usages.limitMonthTotal?.limit
            )
        } catch {
            throw UsageAPIError.malformedResponse
        }
    }
}

private struct RawUsageResponse: Decodable {
    let usages: RawUsages
}

private struct RawUsages: Decodable {
    let limitMonthTotal: RawLimit?
    let limit5h: RawLimit?

    enum CodingKeys: String, CodingKey {
        case limitMonthTotal = "limit_month_total"
        case limit5h = "limit_5h"
    }
}

private struct RawLimit: Decodable {
    let remainingRatio: Double?
    let resetTime: Date?

    enum CodingKeys: String, CodingKey {
        case usedRatio = "used_ratio"
        case resetTime = "reset_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let usedRatio = (try? container.decode(Double.self, forKey: .usedRatio))
            ?? (try? container.decode(String.self, forKey: .usedRatio)).flatMap(Double.init)
        if let usedRatio, usedRatio.isFinite, (0 ... 1).contains(usedRatio) {
            remainingRatio = 1 - usedRatio
        } else {
            remainingRatio = nil
        }
        if let value = try? container.decode(String.self, forKey: .resetTime) {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions.insert(.withFractionalSeconds)
            resetTime = fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        } else {
            resetTime = (try? container.decodeIfPresent(Date.self, forKey: .resetTime)) ?? nil
        }
    }

    var limit: UsageLimit? {
        guard let remainingRatio else { return nil }
        return UsageLimit(remainingRatio: remainingRatio, resetTime: resetTime)
    }
}
