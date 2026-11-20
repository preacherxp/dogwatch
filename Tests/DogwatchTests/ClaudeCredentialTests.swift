import Foundation
import XCTest
@testable import Dogwatch

final class ClaudeCredentialTests: XCTestCase {
    func testUsageRequestGoesOnlyToAnthropicOverHTTPS() {
        let request = ClaudeUsageClient.makeUsageRequest(token: "test-token")

        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.url?.path, "/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSessionKeepsNothingOnDisk() {
        let configuration = ClaudeUsageClient.session.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForResource, 15)
    }

    func testSessionRefusesRedirects() {
        let session = ClaudeUsageClient.session
        let delegate = session.delegate as? URLSessionTaskDelegate
        let task = session.dataTask(with: ClaudeUsageClient.usageURL)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: ClaudeUsageClient.usageURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected: URLRequest? = URLRequest(url: URL(string: "https://example.com/")!)

        delegate?.urlSession?(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: URL(string: "https://example.com/")!)) { redirected = $0 }

        XCTAssertNotNil(delegate)
        XCTAssertNil(redirected)
    }

    func testStatusLineCacheIsOnlyUnderDogwatchSupport() {
        let path = ClaudeUsageClient.statusLineCacheURL.path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/Dogwatch/claude-rate-limits.json"), path)
    }

    func testParsesStatusLineRateLimits() throws {
        let data = Data("""
        {"five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
         "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600}}
        """.utf8)
        let modifiedAt = Date(timeIntervalSince1970: 1_738_400_000)

        let snapshot = try ClaudeUsageClient.parseStatusLineCache(data, modifiedAt: modifiedAt)

        XCTAssertEqual(snapshot.fiveHourUsedPercent, 24)
        XCTAssertEqual(snapshot.fiveHourResetDate, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertEqual(snapshot.weeklyUsedPercent, 41)
        XCTAssertEqual(snapshot.weeklyResetDate, Date(timeIntervalSince1970: 1_738_857_600))
        XCTAssertEqual(snapshot.cacheUpdatedAt, modifiedAt)

        let weekOnly = try ClaudeUsageClient.parseStatusLineCache(
            Data(#"{"seven_day": {"used_percentage": 10, "resets_at": 1738857600}}"#.utf8),
            modifiedAt: modifiedAt
        )
        XCTAssertNil(weekOnly.fiveHourUsedPercent)
        XCTAssertEqual(weekOnly.weeklyUsedPercent, 10)

        XCTAssertThrowsError(try ClaudeUsageClient.parseStatusLineCache(Data("not json".utf8), modifiedAt: modifiedAt))
    }
}
