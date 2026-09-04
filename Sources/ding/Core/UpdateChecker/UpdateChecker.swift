import Combine
import Foundation
import os

/// Protocol abstracting HTTP data requests for testability and mocking.
public protocol UpdateCheckingSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateCheckingSession {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.data(for: request, delegate: nil)
    }
}

/// Internal model representing the JSON payload returned by GitHub's latest release API.
struct GitHubReleasePayload: Decodable, Sendable {
    let tagName: String
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// Service responsible for querying GitHub's public API to check for newer application releases.
///
/// Follows the same `@MainActor`-isolated `ObservableObject` pattern as `AppPreferences` and `AccountManager`
/// to provide safe, reactive state updates to SwiftUI views on macOS 13+.
@MainActor
public final class UpdateChecker: ObservableObject {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "UpdateChecker")

    /// The shared singleton instance of `UpdateChecker`.
    public static let shared = UpdateChecker()

    public static let defaultEndpoint = URL(string: "https://api.github.com/repos/rohpod/ding/releases/latest")!

    // MARK: - Published State

    /// Indicates whether an update check network request is actively in progress.
    @Published public private(set) var isChecking: Bool = false

    /// The most recent result obtained from checking for updates, if any.
    @Published public private(set) var lastResult: UpdateCheckResult?

    // MARK: - Dependencies

    private let endpoint: URL
    private let session: UpdateCheckingSession
    private let currentVersionProvider: @Sendable () -> String

    // MARK: - Initialization

    /// Initializes an `UpdateChecker` with customizable networking and version dependencies.
    ///
    /// - Parameters:
    ///   - endpoint: The GitHub API release endpoint URL. Defaults to `defaultEndpoint`.
    ///   - session: The networking session conforming to `UpdateCheckingSession`. Defaults to `URLSession.shared`.
    ///   - currentVersionProvider: Closure providing the running application version string. Defaults to Bundle.main query.
    public init(
        endpoint: URL = defaultEndpoint,
        session: UpdateCheckingSession = URLSession.shared,
        currentVersionProvider: @escaping @Sendable () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.currentVersionProvider = currentVersionProvider
    }

    // MARK: - Public API

    /// Checks the configured GitHub repository for a newer release tag.
    ///
    /// Compares the remote tag against the currently running version using semantic versioning.
    /// Catches and reports network errors, rate-limiting, and missing releases gracefully.
    ///
    /// - Returns: An `UpdateCheckResult` indicating up-to-date, update-available, or failure.
    @discardableResult
    public func checkForUpdate() async -> UpdateCheckResult {
        guard !isChecking else {
            Self.logger.debug("Update check already in progress; ignoring duplicate request.")
            return lastResult ?? .failed(reason: "Update check already in progress.")
        }

        isChecking = true
        defer { isChecking = false }

        let currentVersionString = currentVersionProvider()
        Self.logger.info("Checking for updates against \(self.endpoint.absoluteString, privacy: .public). Current app version: \(currentVersionString, privacy: .public)")

        guard let currentSemVer = SemanticVersion(string: currentVersionString) else {
            Self.logger.error("Failed to parse running app version: \(currentVersionString, privacy: .public)")
            let result = UpdateCheckResult.failed(reason: "Invalid current app version: \(currentVersionString)")
            self.lastResult = result
            return result
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ding-macOS", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15.0

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("Network request failed during update check: \(error.localizedDescription, privacy: .public)")
            let result = UpdateCheckResult.failed(reason: "Couldn't check for updates right now.")
            self.lastResult = result
            AppPreferences.shared.lastUpdateCheckDate = Date()
            return result
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.error("Unexpected non-HTTP response received during update check.")
            let result = UpdateCheckResult.failed(reason: "Invalid server response.")
            self.lastResult = result
            AppPreferences.shared.lastUpdateCheckDate = Date()
            return result
        }

        Self.logger.debug("GitHub API response status code: \(httpResponse.statusCode)")

        // Handle HTTP Rate Limiting (403)
        if httpResponse.statusCode == 403 {
            Self.logger.warning("GitHub API rate limit exceeded or access forbidden (HTTP 403).")
            let result = UpdateCheckResult.failed(reason: "Rate limit reached. Please try again later.")
            self.lastResult = result
            AppPreferences.shared.lastUpdateCheckDate = Date()
            return result
        }

        // Handle Not Found (404) - e.g. repository has no published releases yet
        if httpResponse.statusCode == 404 {
            Self.logger.info("GitHub API returned 404 Not Found (no releases published yet).")
            let result = UpdateCheckResult.failed(reason: "No releases found.")
            self.lastResult = result
            AppPreferences.shared.lastUpdateCheckDate = Date()
            return result
        }

        // Validate HTTP 200..299
        guard (200...299).contains(httpResponse.statusCode) else {
            Self.logger.warning("GitHub API returned error status: \(httpResponse.statusCode)")
            let result = UpdateCheckResult.failed(reason: "Couldn't check for updates right now (status \(httpResponse.statusCode)).")
            self.lastResult = result
            AppPreferences.shared.lastUpdateCheckDate = Date()
            return result
        }

        // Parse JSON payload
        let releasePayload: GitHubReleasePayload
        do {
            releasePayload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        } catch {
            Self.logger.error("Failed to parse GitHub release JSON: \(error.localizedDescription, privacy: .public)")
            let result = UpdateCheckResult.failed(reason: "Failed to parse release information.")
            self.lastResult = result
            AppPreferences.shared.lastUpdateCheckDate = Date()
            return result
        }

        guard let remoteSemVer = SemanticVersion(string: releasePayload.tagName) else {
            Self.logger.warning("Failed to parse remote release tag name: \(releasePayload.tagName, privacy: .public)")
            let result = UpdateCheckResult.failed(reason: "Unrecognized release version tag: \(releasePayload.tagName)")
            self.lastResult = result
            AppPreferences.shared.lastUpdateCheckDate = Date()
            return result
        }

        let result: UpdateCheckResult
        if remoteSemVer.isNewer(than: currentSemVer) {
            let releasePageURL = releasePayload.htmlURL.flatMap { URL(string: $0) }
                ?? URL(string: "https://github.com/rohpod/ding/releases")!
            Self.logger.info("Newer release found: \(releasePayload.tagName, privacy: .public) (current: \(currentVersionString, privacy: .public))")
            result = .updateAvailable(
                currentVersion: currentVersionString,
                latestVersion: releasePayload.tagName,
                releaseURL: releasePageURL
            )
        } else {
            Self.logger.info("ding is up to date (\(currentVersionString, privacy: .public) >= \(releasePayload.tagName, privacy: .public))")
            result = .upToDate(currentVersion: currentVersionString)
        }

        self.lastResult = result
        AppPreferences.shared.lastUpdateCheckDate = Date()
        return result
    }
}
