import Foundation

/// Where sign-in to a service stands, as far as a view waiting on it cares.
public enum SignInStatus: Equatable, Sendable {
    /// The service isn't set up, so sign-in can never be what fixes a failure.
    case notConfigured
    /// No sign-in has finished yet: the app is starting, or an attempt is running.
    case signingIn
    case signedIn
    /// The last sign-in attempt failed. A later one (Retry, Settings) can still succeed.
    case failed
}

/// What a view does with a request that failed — the decision behind a link
/// that opens before sign-in has finished.
///
/// A link that launches the app reaches its view within a second, long before
/// the silent sign-in completes, so the first request fails as "not
/// authenticated". Reporting that as final left the view stuck on an error
/// that sign-in fixes a moment later.
public enum SignInRetry: Equatable, Sendable {
    /// Sign-in isn't the cause: report the failure.
    case showError
    /// Sign-in finished while the request was in flight: run it again now,
    /// since the change that would have re-run it has already passed.
    case retryNow
    /// Hold the request and run it again once sign-in completes.
    case waitForSignIn

    /// - Parameters:
    ///   - startedSignedIn: whether the service was signed in when the request began.
    ///   - status: where sign-in stands now that the request has failed.
    public static func afterFailure(startedSignedIn: Bool, status: SignInStatus) -> SignInRetry {
        switch status {
        case .notConfigured:
            return .showError
        case .signedIn:
            return startedSignedIn ? .showError : .retryNow
        case .signingIn, .failed:
            return .waitForSignIn
        }
    }
}

/// What a Retry button does after a request failed: a Retry that only
/// reloaded, while signed out, failed again the same way.
public enum SignInRetryTap: Equatable, Sendable {
    /// Reload now.
    case reload
    /// Start sign-in, hold the request, and reload once sign-in completes.
    case signInThenReload
    /// A sign-in attempt is already running: hold the request until it finishes.
    case waitForSignIn

    public static func decide(status: SignInStatus) -> SignInRetryTap {
        switch status {
        case .notConfigured, .signedIn: return .reload
        case .failed: return .signInThenReload
        case .signingIn: return .waitForSignIn
        }
    }
}
