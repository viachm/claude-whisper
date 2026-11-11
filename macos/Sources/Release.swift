import Foundation

/// A release version such as "0.1.9" or "v0.1.10", compared number by number ("0.1.10" is newer
/// than "0.1.9", and "0.2" equals "0.2.0"). Anything after a "-" is ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.first == "v" || core.first == "V" { core.removeFirst() }
        core = String(core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = numbers.map { $0! }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private static func padded(_ a: AppVersion, _ b: AppVersion) -> ([Int], [Int]) {
        let n = max(a.parts.count, b.parts.count)
        return (a.parts + Array(repeating: 0, count: n - a.parts.count),
                b.parts + Array(repeating: 0, count: n - b.parts.count))
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { let (x, y) = padded(a, b); return x == y }
    static func < (a: AppVersion, b: AppVersion) -> Bool { let (x, y) = padded(a, b); return x.lexicographicallyPrecedes(y) }
}

/// The parts of GitHub's "latest release" answer the updater needs.
struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let url: URL
        /// "sha256:<hex>", which GitHub works out for every uploaded asset.
        let digest: String?

        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url", digest }
    }

    let tag: String
    let page: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey { case tag = "tag_name", page = "html_url", assets }

    static let latestURL = URL(string: "https://api.github.com/repos/viachm/claude-whisper/releases/latest")!
    static let macAsset = "Claude-Whisper-macOS.zip"

    var version: AppVersion? { AppVersion(tag) }

    func asset(named name: String) -> Asset? { assets.first { $0.name == name } }

    /// The lowercase hex SHA-256 from the digest, if GitHub gave one.
    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? String(hex) : nil
    }
}
