import XCTest
@testable import ding

final class SemanticVersionTests: XCTestCase {
    // MARK: - Parsing Tests

    func testSemanticVersionParsing() {
        let v1 = SemanticVersion(string: "0.1.0")
        XCTAssertNotNil(v1)
        XCTAssertEqual(v1?.major, 0)
        XCTAssertEqual(v1?.minor, 1)
        XCTAssertEqual(v1?.patch, 0)
        XCTAssertNil(v1?.prerelease)

        let v2 = SemanticVersion(string: "v0.1.0")
        XCTAssertNotNil(v2)
        XCTAssertEqual(v2?.major, 0)
        XCTAssertEqual(v2?.minor, 1)
        XCTAssertEqual(v2?.patch, 0)

        let v3 = SemanticVersion(string: "V1.2.3")
        XCTAssertNotNil(v3)
        XCTAssertEqual(v3?.major, 1)
        XCTAssertEqual(v3?.minor, 2)
        XCTAssertEqual(v3?.patch, 3)

        let vShort = SemanticVersion(string: "1.2")
        XCTAssertNotNil(vShort)
        XCTAssertEqual(vShort?.major, 1)
        XCTAssertEqual(vShort?.minor, 2)
        XCTAssertEqual(vShort?.patch, 0)

        let vSingle = SemanticVersion(string: "2")
        XCTAssertNotNil(vSingle)
        XCTAssertEqual(vSingle?.major, 2)
        XCTAssertEqual(vSingle?.minor, 0)
        XCTAssertEqual(vSingle?.patch, 0)

        let vPre = SemanticVersion(string: "1.0.0-beta.1")
        XCTAssertNotNil(vPre)
        XCTAssertEqual(vPre?.major, 1)
        XCTAssertEqual(vPre?.minor, 0)
        XCTAssertEqual(vPre?.patch, 0)
        XCTAssertEqual(vPre?.prerelease, "beta.1")

        let vWhitespace = SemanticVersion(string: "   v3.4.5   ")
        XCTAssertNotNil(vWhitespace)
        XCTAssertEqual(vWhitespace?.major, 3)
        XCTAssertEqual(vWhitespace?.minor, 4)
        XCTAssertEqual(vWhitespace?.patch, 5)
    }

    // MARK: - Comparison Tests: Update Available

    func testSemanticVersionComparisonUpdateAvailable() {
        // "0.1.0 vs 0.2.0 → update available"
        let current = SemanticVersion(string: "0.1.0")!
        let latest = SemanticVersion(string: "0.2.0")!
        XCTAssertTrue(latest.isNewer(than: current))
        XCTAssertTrue(current < latest)
        XCTAssertFalse(current > latest)

        // Patch update
        let currentPatch = SemanticVersion(string: "0.1.0")!
        let latestPatch = SemanticVersion(string: "0.1.1")!
        XCTAssertTrue(latestPatch.isNewer(than: currentPatch))

        // Major update
        let currentMajor = SemanticVersion(string: "0.9.9")!
        let latestMajor = SemanticVersion(string: "1.0.0")!
        XCTAssertTrue(latestMajor.isNewer(than: currentMajor))
    }

    // MARK: - Comparison Tests: Numeric vs String Ordering

    func testSemanticVersionComparisonNumericVsStringComparison() {
        // Specifically tests the common naive string comparison bug where "0.10.0" < "0.9.0"
        let v10 = SemanticVersion(string: "0.10.0")!
        let v9 = SemanticVersion(string: "0.9.0")!

        // "0.10.0 vs 0.9.0 → up to date, no update"
        XCTAssertTrue(v10 > v9, "0.10.0 must be greater than 0.9.0 numerically")
        XCTAssertFalse(v9.isNewer(than: v10), "0.9.0 is not newer than 0.10.0")
        XCTAssertTrue(v10.isNewer(than: v9))

        // 0.9.0 vs 0.10.0 -> update available
        XCTAssertTrue(v9 < v10)

        // Triple digit patch vs single digit patch
        let vPatchHigh = SemanticVersion(string: "1.2.100")!
        let vPatchLow = SemanticVersion(string: "1.2.99")!
        XCTAssertTrue(vPatchHigh > vPatchLow)

        // Major comparison
        let vMajor10 = SemanticVersion(string: "10.0.0")!
        let vMajor9 = SemanticVersion(string: "9.9.9")!
        XCTAssertTrue(vMajor10 > vMajor9)
    }

    // MARK: - Comparison Tests: Equality & "v" Prefix Stripping

    func testSemanticVersionComparisonEqualAndVPrefix() {
        // "0.1.0 vs 0.1.0 → up to date"
        let current = SemanticVersion(string: "0.1.0")!
        let target = SemanticVersion(string: "0.1.0")!
        XCTAssertEqual(current, target)
        XCTAssertFalse(target.isNewer(than: current))

        // "v0.1.0 vs 0.1.0"
        let vPrefixed = SemanticVersion(string: "v0.1.0")!
        XCTAssertEqual(vPrefixed, current)
        XCTAssertFalse(vPrefixed.isNewer(than: current))

        // "v" prefix with newer version
        let latestPrefixed = SemanticVersion(string: "v0.2.0")!
        XCTAssertTrue(latestPrefixed.isNewer(than: current))

        // Equivalent omitted zero components
        let vTwo = SemanticVersion(string: "1.0")!
        let vThree = SemanticVersion(string: "1.0.0")!
        XCTAssertEqual(vTwo, vThree)
    }

    // MARK: - Comparison Tests: Prerelease

    func testSemanticVersionComparisonPrerelease() {
        let release = SemanticVersion(string: "1.0.0")!
        let preRelease = SemanticVersion(string: "1.0.0-alpha")!
        let preReleaseBeta = SemanticVersion(string: "1.0.0-beta")!

        XCTAssertTrue(release > preRelease, "Final release must take precedence over prerelease")
        XCTAssertTrue(preReleaseBeta > preRelease, "beta should be greater than alpha")
        XCTAssertTrue(release.isNewer(than: preRelease))
    }

    // MARK: - Invalid Version Tests

    func testSemanticVersionInvalidStrings() {
        XCTAssertNil(SemanticVersion(string: ""))
        XCTAssertNil(SemanticVersion(string: "   "))
        XCTAssertNil(SemanticVersion(string: "v"))
        XCTAssertNil(SemanticVersion(string: "alpha"))
        XCTAssertNil(SemanticVersion(string: "1.2.3.4"))
        XCTAssertNil(SemanticVersion(string: "-1.0.0"))
        XCTAssertNil(SemanticVersion(string: "1.-2.0"))
        XCTAssertNil(SemanticVersion(string: "1.x.0"))
    }
}
