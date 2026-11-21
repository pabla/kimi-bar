import Foundation

protocol UsageFetching {
    func fetchUsage() async throws -> UsageSnapshot
}

struct AuthenticatedUsageFetcher: UsageFetching {
    private let usageAPIClient: any UsageAPIFetching
    private let credentialManager: any CredentialManaging

    init(usageAPIClient: any UsageAPIFetching, credentialManager: any CredentialManaging) {
        self.usageAPIClient = usageAPIClient
        self.credentialManager = credentialManager
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let credentials = try await credentialManager.credentials(forceRefresh: false)
        do {
            return try await usageAPIClient.fetchUsage(accessToken: credentials.accessToken)
        } catch UsageAPIError.httpStatus(401, retryAfter: _) {
            let refreshed = try await credentialManager.credentials(forceRefresh: true)
            return try await usageAPIClient.fetchUsage(accessToken: refreshed.accessToken)
        }
    }
}
