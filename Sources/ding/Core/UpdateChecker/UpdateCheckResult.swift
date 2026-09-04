import Foundation

/// The result of an update check operation against the GitHub Releases API.
public enum UpdateCheckResult: Equatable, Sendable {
    /// The currently running version is up to date with the latest release.
    case upToDate(currentVersion: String)

    /// A newer version of the application is available.
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL)

    /// The update check could not be completed (e.g. rate limit, network failure, or no releases).
    case failed(reason: String)

    /// Indicates whether a newer version is available.
    public var isUpdateAvailable: Bool {
        if case .updateAvailable = self {
            return true
        }
        return false
    }

    /// The latest release version tag if available.
    public var latestVersion: String? {
        if case let .updateAvailable(_, latest, _) = self {
            return latest
        }
        return nil
    }

    /// The URL to the release page on GitHub if an update is available.
    public var releaseURL: URL? {
        if case let .updateAvailable(_, _, url) = self {
            return url
        }
        return nil
    }
}
