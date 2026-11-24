import CoreFoundation
import Foundation

struct KimiCredentials: Equatable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let expiresIn: TimeInterval

    var description: String {
        "<KimiCredentials redacted>"
    }

    var debugDescription: String {
        description
    }
}

struct KimiDeviceAuthorization: Sendable {
    let userCode: String
    let deviceCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

enum KimiCredentialError: Error, Equatable, LocalizedError {
    case authenticationRequired
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "Authentication required"
        case .storageUnavailable: "Credential storage is unavailable. Try again."
        }
    }
}

enum KimiOAuthError: Error, Equatable, LocalizedError {
    case authorizationDenied
    case deviceCodeExpired
    case authorizationTimedOut
    case malformedResponse
    case authorizationFailed
    case refreshFailed
    case browserOpenFailed

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Sign-in was denied. You can try again."
        case .deviceCodeExpired:
            "The sign-in code expired. Try again."
        case .authorizationTimedOut:
            "Sign-in timed out. Try again."
        case .malformedResponse:
            "Kimi returned an invalid sign-in response. Try again."
        case .authorizationFailed:
            "Sign-in failed. Try again."
        case .refreshFailed:
            "Session refresh failed. Try again later."
        case .browserOpenFailed:
            "Kimi Bar couldn't open your default browser."
        }
    }
}

protocol CredentialManaging {
    func credentials(forceRefresh: Bool) async throws -> KimiCredentials
}

protocol AuthenticationManaging {
    func beginDeviceAuthorization() async throws -> KimiDeviceAuthorization
    func completeDeviceAuthorization(_ authorization: KimiDeviceAuthorization) async throws
    func signOut() throws
}

final class KimiCredentialManager: CredentialManaging, AuthenticationManaging, @unchecked Sendable {
    private static let deviceAuthorizationURL = URL(string: "https://auth.kimi.ai/api/oauth/device_authorization")!
    private static let oauthURL = URL(string: "https://auth.kimi.ai/api/oauth/token")!
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    private let store: any KimiCredentialStoring
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let credentialMutationLock = NSLock()

    convenience init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(store: KeychainCredentialStore(), session: session, now: now)
    }

    init(
        store: any KimiCredentialStoring,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(min(interval, 86400) * 1_000_000_000))
        }
    ) {
        self.store = store
        self.session = session
        self.now = now
        self.sleep = sleep
    }

    /// Pass forceRefresh after one usage 401.
    func credentials(forceRefresh: Bool = false) async throws -> KimiCredentials {
        try await loadFreshCredentials(forceRefresh: forceRefresh)
    }

    func beginDeviceAuthorization() async throws -> KimiDeviceAuthorization {
        let (status, object) = try await request(
            url: Self.deviceAuthorizationURL,
            fields: ["client_id": Self.clientID]
        )
        guard status == 200,
              let userCode = object["user_code"] as? String, !userCode.isEmpty,
              let deviceCode = object["device_code"] as? String, !deviceCode.isEmpty,
              let verificationString = object["verification_uri_complete"] as? String,
              let verificationURL = URL(string: verificationString),
              Self.isKimiVerificationURL(verificationURL),
              let expiresIn = Self.responseNumber(object["expires_in"]),
              expiresIn.isFinite, expiresIn > 0
        else { throw KimiOAuthError.malformedResponse }
        let interval = Self.responseNumber(object["interval"]) ?? 5
        guard interval.isFinite, interval > 0 else { throw KimiOAuthError.malformedResponse }
        return KimiDeviceAuthorization(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURL: verificationURL,
            expiresAt: now().addingTimeInterval(expiresIn),
            interval: interval
        )
    }

    func completeDeviceAuthorization(_ authorization: KimiDeviceAuthorization) async throws {
        var interval = authorization.interval
        while true {
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else {
                throw KimiOAuthError.authorizationTimedOut
            }
            let (status, object) = try await request(
                url: Self.oauthURL,
                fields: [
                    "client_id": Self.clientID,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            if status == 200 {
                let credentials = try Self.credentials(from: object, now: now())
                try saveCredentials(credentials)
                return
            }
            guard let error = object["error"] as? String else {
                throw KimiOAuthError.malformedResponse
            }
            switch error {
            case "authorization_pending", "slow_down":
                if error == "slow_down" {
                    interval += 5
                }
                try await sleep(interval)
            case "access_denied":
                throw KimiOAuthError.authorizationDenied
            case "expired_token":
                throw KimiOAuthError.deviceCodeExpired
            default:
                throw KimiOAuthError.authorizationFailed
            }
        }
    }

    func signOut() throws {
        credentialMutationLock.lock()
        defer { credentialMutationLock.unlock() }
        try store.deleteCredentials()
    }

    private func saveCredentials(_ credentials: KimiCredentials) throws {
        credentialMutationLock.lock()
        defer { credentialMutationLock.unlock() }
        try Task.checkCancellation()
        try store.saveCredentials(credentials)
    }

    private func loadFreshCredentials(forceRefresh: Bool) async throws -> KimiCredentials {
        guard let current = try store.loadCredentials(), !current.accessToken.isEmpty else {
            throw KimiCredentialError.authenticationRequired
        }
        if !forceRefresh && !needsRefresh(current) {
            return current
        }
        guard !current.refreshToken.isEmpty else {
            throw KimiCredentialError.authenticationRequired
        }

        let (status, object) = try await request(
            url: Self.oauthURL,
            fields: [
                "client_id": Self.clientID,
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
            ]
        )
        guard status == 200 else {
            if status == 400 || status == 401 || status == 403 {
                throw KimiCredentialError.authenticationRequired
            }
            throw KimiOAuthError.refreshFailed
        }
        let refreshed = try Self.credentials(
            from: object, now: now(), fallbackRefreshToken: current.refreshToken
        )
        try saveCredentials(refreshed)
        return refreshed
    }

    private func needsRefresh(_ credentials: KimiCredentials) -> Bool {
        guard credentials.expiresAt.timeIntervalSince1970 != 0 else { return false }
        let threshold = max(300, credentials.expiresIn * 0.5)
        return credentials.expiresAt.timeIntervalSince(now()) < threshold
    }

    private func request(
        url: URL, fields: [String: String]
    ) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw KimiOAuthError.malformedResponse
        }
        let object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        return (status, object)
    }

    private static func credentials(
        from object: [String: Any], now: Date, fallbackRefreshToken: String? = nil
    ) throws -> KimiCredentials {
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = (object["refresh_token"] as? String) ?? fallbackRefreshToken,
              !refreshToken.isEmpty,
              let expiresIn = responseNumber(object["expires_in"]),
              expiresIn.isFinite, expiresIn > 0
        else { throw KimiOAuthError.malformedResponse }
        return KimiCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + expiresIn),
            expiresIn: expiresIn
        )
    }

    private static func isKimiVerificationURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["kimi.ai", "kimi.com"].contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static func responseNumber(_ value: Any?) -> Double? {
        if let string = value as? String {
            return Double(string)
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }
}
