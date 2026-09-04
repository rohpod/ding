import Foundation

/// A structured representation of a Semantic Version (SemVer 2.0-compatible).
///
/// Parses versions in formats like `"0.1.0"`, `"v1.2.3"`, `"0.1"`, `"1.0.0-beta"`,
/// and performs numeric comparison rather than naive lexical string comparison.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    /// The major version component (e.g. 1 in 1.2.3).
    public let major: Int

    /// The minor version component (e.g. 2 in 1.2.3).
    public let minor: Int

    /// The patch version component (e.g. 3 in 1.2.3).
    public let patch: Int

    /// An optional prerelease tag (e.g. "beta.1" in 1.0.0-beta.1).
    public let prerelease: String?

    /// The original raw string passed to the initializer.
    public let rawString: String

    public var description: String {
        var result = "\(major).\(minor).\(patch)"
        if let prerelease = prerelease, !prerelease.isEmpty {
            result += "-\(prerelease)"
        }
        return result
    }

    /// Initializes a `SemanticVersion` from a version string.
    ///
    /// Strips leading `"v"` or `"V"` and parses up to 3 numeric segments separated by dots.
    /// Returns `nil` if the string contains non-numeric characters in the version core or negative integers.
    ///
    /// - Parameter string: The version string to parse.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawString = trimmed

        var cleaned = trimmed
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }

        guard !cleaned.isEmpty else { return nil }

        // Split off prerelease metadata (e.g., "1.0.0-beta" -> core "1.0.0", prerelease "beta")
        let parts = cleaned.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let versionCore = String(parts[0])
        let prereleaseTag = parts.count > 1 ? String(parts[1]) : nil

        let numericSegments = versionCore.split(separator: ".", omittingEmptySubsequences: false)
        guard !numericSegments.isEmpty, numericSegments.count <= 3 else { return nil }

        var numbers: [Int] = []
        for segment in numericSegments {
            guard let number = Int(segment), number >= 0 else { return nil }
            numbers.append(number)
        }

        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
        self.prerelease = prereleaseTag?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Comparable

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        if lhs.patch != rhs.patch {
            return lhs.patch < rhs.patch
        }

        // Per SemVer specification: a release version has higher precedence than a prerelease version.
        // E.g., 1.0.0-alpha < 1.0.0
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(lhsPre), .some(rhsPre)):
            return lhsPre < rhsPre
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        return lhs.major == rhs.major &&
               lhs.minor == rhs.minor &&
               lhs.patch == rhs.patch &&
               lhs.prerelease == rhs.prerelease
    }

    /// Returns `true` if this version is strictly newer than the given version.
    public func isNewer(than other: SemanticVersion) -> Bool {
        return self > other
    }
}
