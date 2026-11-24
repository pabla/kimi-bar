import Combine
import Foundation

enum AuthenticatedUsageSessionPhase: Equatable {
    case restoring
    case signedOut
    case signingIn
    case signedIn
    case failed
}

struct AuthenticatedUsageSessionState: Equatable {
    let phase: AuthenticatedUsageSessionPhase
    let snapshot: UsageSnapshot?
    let lastSuccessfulUpdate: Date?
    let isRefreshing: Bool
    let isStale: Bool
    let authenticationFailureReason: String?
    let usageFailureReason: String?
    let userCode: String?

    var canRefresh: Bool {
        phase == .restoring || phase == .signedIn
    }
}

@MainActor
final class AuthenticatedUsageSession: ObservableObject {
    var state: AuthenticatedUsageSessionState {
        let usageFailureReason: String?
        if phase == .signingIn, Self.authenticationFailure(from: usage.state.error) != nil {
            usageFailureReason = nil
        } else if usage.state.isStale, let error = usage.state.error {
            usageFailureReason = Self.authenticationFailure(from: error) == nil
                ? error.localizedDescription
                : KimiCredentialError.authenticationRequired.localizedDescription
        } else {
            usageFailureReason = nil
        }
        return AuthenticatedUsageSessionState(
            phase: phase,
            snapshot: usage.state.snapshot,
            lastSuccessfulUpdate: usage.state.lastSuccessfulUpdate,
            isRefreshing: usage.state.isRefreshing,
            isStale: usage.state.isStale,
            authenticationFailureReason: authenticationFailureReason,
            usageFailureReason: usageFailureReason,
            userCode: phase == .signingIn ? userCode : nil
        )
    }

    private var phase: AuthenticatedUsageSessionPhase = .restoring
    private var authenticationFailureReason: String?
    private var userCode: String?
    private let manager: any AuthenticationManaging
    private let openBrowser: (URL) -> Bool
    private let usage: UsageRefreshCoordinator
    private var signInTask: Task<Void, Never>?
    private var signInID: UUID?

    init(
        manager: any AuthenticationManaging,
        fetcher: any UsageFetching,
        store: any UsageSnapshotStoring,
        clock: any UsageRefreshClock = SystemUsageRefreshClock(),
        openBrowser: @escaping (URL) -> Bool
    ) {
        self.manager = manager
        self.openBrowser = openBrowser
        let usage = UsageRefreshCoordinator(fetcher: fetcher, clock: clock, store: store)
        self.usage = usage
        usage.onChange = { [weak self] in self?.updateFromInternals() }
    }

    func start() {
        guard phase == .restoring || phase == .signedIn else { return }
        usage.start()
    }

    func refresh() {
        guard phase == .restoring || phase == .signedIn else { return }
        usage.refresh()
    }

    func popoverOpened() {
        guard phase == .restoring || phase == .signedIn else { return }
        usage.popoverOpened()
    }

    func signIn() {
        guard phase == .signedOut || phase == .failed else { return }
        let id = UUID()
        signInID = id
        authenticationFailureReason = nil
        userCode = nil
        phase = .signingIn
        usage.stop()
        publish()
        signInTask = Task { [manager] in
            do {
                let authorization = try await manager.beginDeviceAuthorization()
                try Task.checkCancellation()
                guard self.signInID == id else { return }
                self.userCode = authorization.userCode
                self.publish()
                guard self.openBrowser(authorization.verificationURL) else {
                    throw KimiOAuthError.browserOpenFailed
                }
                try await manager.completeDeviceAuthorization(authorization)
                try Task.checkCancellation()
                self.finishSignIn(id: id, error: nil)
            } catch {
                self.finishSignIn(id: id, error: error)
            }
        }
    }

    func cancelSignIn() {
        guard phase == .signingIn else { return }
        signOut()
    }

    func signOut() {
        signInID = nil
        signInTask?.cancel()
        signInTask = nil
        userCode = nil
        usage.stop()
        do {
            try manager.signOut()
            authenticationFailureReason = nil
            phase = .signedOut
            usage.signedOut()
        } catch {
            authenticationFailureReason = "Sign-out failed. Try again."
            if phase == .signingIn {
                phase = .failed
            }
            if phase == .restoring || phase == .signedIn {
                usage.start()
            }
        }
        publish()
    }

    private func finishSignIn(id: UUID, error: Error?) {
        guard signInID == id else { return }
        signInTask = nil
        signInID = nil
        userCode = nil
        if Task.isCancelled || error is CancellationError {
            authenticationFailureReason = nil
            phase = .signedOut
            usage.stop()
        } else if let error {
            phase = .failed
            if let oauthError = error as? KimiOAuthError {
                authenticationFailureReason = oauthError.localizedDescription
            } else if let credentialError = error as? KimiCredentialError {
                authenticationFailureReason = credentialError.localizedDescription
            } else {
                authenticationFailureReason = "Sign-in failed. Check your connection and try again."
            }
        } else {
            authenticationFailureReason = nil
            phase = .signedIn
            usage.start()
        }
        publish()
    }

    private func updateFromInternals() {
        let usageState = usage.state
        if !usageState.isRefreshing {
            if let failure = Self.authenticationFailure(from: usageState.error) {
                switch (phase, failure) {
                case (.restoring, .credentialsRequired):
                    phase = .signedOut
                    usage.stop()
                case (.restoring, .reauthenticationRequired), (.signedIn, _):
                    phase = .failed
                    authenticationFailureReason = KimiCredentialError.authenticationRequired.localizedDescription
                    usage.stop()
                default:
                    break
                }
            } else if phase == .restoring,
                      usageState.error as? KimiCredentialError == .storageUnavailable
            {
                phase = .failed
                authenticationFailureReason = usageState.error?.localizedDescription
                usage.stop()
            } else if phase == .restoring, usageState.error != nil {
                phase = .signedIn
            } else if phase == .restoring,
                      usageState.lastSuccessfulUpdate != nil,
                      !usageState.isStale,
                      usageState.error == nil
            {
                phase = .signedIn
            }
        }
        publish()
    }

    private func publish() {
        objectWillChange.send()
    }

    private static func authenticationFailure(from error: Error?) -> AuthenticationFailure? {
        guard let error else { return nil }
        if (error as? KimiCredentialError) == .authenticationRequired {
            return .credentialsRequired
        }
        if case UsageAPIError.httpStatus(401, retryAfter: _) = error {
            return .reauthenticationRequired
        }
        return nil
    }

    private enum AuthenticationFailure {
        case credentialsRequired
        case reauthenticationRequired
    }
}
