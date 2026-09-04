import XCTest
@testable import ding

/// Mock implementation of `UpdateCheckingSession` for deterministic unit testing.
final class MockUpdateCheckingSession: UpdateCheckingSession, @unchecked Sendable {
    var responseHandler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(responseHandler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.responseHandler = responseHandler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try responseHandler(request)
    }
}

/// Helper for constructing mock HTTP responses without capturing actor state.
private nonisolated func createMockResponse(
    statusCode: Int,
    body: String,
    url: URL = URL(string: "https://api.github.com/repos/test-org/ding/releases/latest")!
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    let data = body.data(using: .utf8) ?? Data()
    return (data, response)
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private let testEndpoint = URL(string: "https://api.github.com/repos/test-org/ding/releases/latest")!

    // MARK: - Update Available Test

    func testUpdateCheckerFindsNewerRelease() async {
        let payload = """
        {
            "tag_name": "v0.2.0",
            "html_url": "https://github.com/rohpod/ding/releases/tag/v0.2.0"
        }
        """

        let session = MockUpdateCheckingSession { _ in
            createMockResponse(statusCode: 200, body: payload)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.1.0" }
        )

        let result = await checker.checkForUpdate()

        guard case let .updateAvailable(current, latest, releaseURL) = result else {
            XCTFail("Expected .updateAvailable, got \(result)")
            return
        }

        XCTAssertEqual(current, "0.1.0")
        XCTAssertEqual(latest, "v0.2.0")
        XCTAssertEqual(releaseURL.absoluteString, "https://github.com/rohpod/ding/releases/tag/v0.2.0")
        XCTAssertTrue(result.isUpdateAvailable)
        XCTAssertEqual(checker.lastResult, result)
        XCTAssertFalse(checker.isChecking)
    }

    // MARK: - Up To Date Tests

    func testUpdateCheckerAppIsUpToDate() async {
        let payload = """
        {
            "tag_name": "v0.1.0",
            "html_url": "https://github.com/rohpod/ding/releases/tag/v0.1.0"
        }
        """

        let session = MockUpdateCheckingSession { _ in
            createMockResponse(statusCode: 200, body: payload)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.1.0" }
        )

        let result = await checker.checkForUpdate()

        guard case let .upToDate(current) = result else {
            XCTFail("Expected .upToDate, got \(result)")
            return
        }

        XCTAssertEqual(current, "0.1.0")
        XCTAssertFalse(result.isUpdateAvailable)
        XCTAssertEqual(checker.lastResult, result)
    }

    func testUpdateCheckerAppIsNewerThanRemoteReleaseNumeric() async {
        // Current is 0.10.0, remote is 0.9.0
        let payload = """
        {
            "tag_name": "v0.9.0",
            "html_url": "https://github.com/rohpod/ding/releases/tag/v0.9.0"
        }
        """

        let session = MockUpdateCheckingSession { _ in
            createMockResponse(statusCode: 200, body: payload)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.10.0" }
        )

        let result = await checker.checkForUpdate()

        guard case let .upToDate(current) = result else {
            XCTFail("Expected .upToDate for 0.10.0 vs 0.9.0, got \(result)")
            return
        }

        XCTAssertEqual(current, "0.10.0")
        XCTAssertFalse(result.isUpdateAvailable)
    }

    // MARK: - GitHub API Error Handling Tests

    func testUpdateCheckerHandles404NoReleases() async {
        let payload = """
        {
            "message": "Not Found"
        }
        """

        let session = MockUpdateCheckingSession { _ in
            createMockResponse(statusCode: 404, body: payload)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.1.0" }
        )

        let result = await checker.checkForUpdate()

        guard case let .failed(reason) = result else {
            XCTFail("Expected .failed for 404, got \(result)")
            return
        }

        XCTAssertEqual(reason, "No releases found.")
        XCTAssertFalse(result.isUpdateAvailable)
        XCTAssertEqual(checker.lastResult, result)
    }

    func testUpdateCheckerHandles403RateLimit() async {
        let payload = """
        {
            "message": "API rate limit exceeded for 127.0.0.1"
        }
        """

        let session = MockUpdateCheckingSession { _ in
            createMockResponse(statusCode: 403, body: payload)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.1.0" }
        )

        let result = await checker.checkForUpdate()

        guard case let .failed(reason) = result else {
            XCTFail("Expected .failed for 403, got \(result)")
            return
        }

        XCTAssertTrue(reason.contains("Rate limit") || reason.contains("rate limit"), "Reason should mention rate limit: \(reason)")
        XCTAssertFalse(result.isUpdateAvailable)
    }

    func testUpdateCheckerHandlesMalformedJSON() async {
        let payload = """
        {
            "some_unexpected_field": 123
        }
        """

        let session = MockUpdateCheckingSession { _ in
            createMockResponse(statusCode: 200, body: payload)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.1.0" }
        )

        let result = await checker.checkForUpdate()

        guard case let .failed(reason) = result else {
            XCTFail("Expected .failed for malformed JSON, got \(result)")
            return
        }

        XCTAssertFalse(reason.isEmpty)
    }

    func testUpdateCheckerHandlesNetworkError() async {
        let session = MockUpdateCheckingSession { _ in
            throw URLError(.notConnectedToInternet)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.1.0" }
        )

        let result = await checker.checkForUpdate()

        guard case let .failed(reason) = result else {
            XCTFail("Expected .failed for network error, got \(result)")
            return
        }

        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Timestamp Updates

    func testUpdateCheckerUpdatesLastCheckTimestamp() async {
        let initialDate = AppPreferences.shared.lastUpdateCheckDate

        let payload = """
        {
            "tag_name": "v0.1.0",
            "html_url": "https://github.com/rohpod/ding/releases/tag/v0.1.0"
        }
        """

        let session = MockUpdateCheckingSession { _ in
            createMockResponse(statusCode: 200, body: payload)
        }

        let checker = UpdateChecker(
            endpoint: testEndpoint,
            session: session,
            currentVersionProvider: { "0.1.0" }
        )

        _ = await checker.checkForUpdate()

        let updatedDate = AppPreferences.shared.lastUpdateCheckDate
        XCTAssertNotNil(updatedDate)
        if let initial = initialDate, let updated = updatedDate {
            XCTAssertTrue(updated >= initial)
        }
    }
}
