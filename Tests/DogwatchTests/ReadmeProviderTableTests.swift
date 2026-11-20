import Foundation
import XCTest
@testable import Dogwatch

/// The README's table of supported providers is generated from the registry. When this test
/// fails, paste the expected table it prints between the markers in README.md.
final class ReadmeProviderTableTests: XCTestCase {
    static func table() -> String {
        var lines = [
            "| Provider | Source | Shows | Needs |",
            "| --- | --- | --- | --- |",
        ]
        for provider in ProviderRegistry.builtIn {
            let descriptor = provider.descriptor
            let needs: String
            switch descriptor.credential {
            case .none: needs = descriptor.localSources.isEmpty ? "Nothing" : "The tool's local data"
            case .toolStore(let store): needs = "Its own sign-in (\(store.kind == .keychain ? "Keychain" : "file"), read only)"
            case .pastedKey(let spec): needs = "Your \(spec.label), pasted in settings"
            }
            lines.append("| \(descriptor.name) (`\(descriptor.id)`) | \(descriptor.source) | \(descriptor.summary) | \(needs) |")
        }
        return lines.joined(separator: "\n")
    }

    func testReadmeTableMatchesTheRegistry() throws {
        let readme = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md"))
        let start = try XCTUnwrap(readme.range(of: "<!-- providers:start -->\n"), "README.md needs the providers:start marker")
        let end = try XCTUnwrap(readme.range(of: "<!-- providers:end -->", range: start.upperBound..<readme.endIndex),
                                "README.md needs the providers:end marker after providers:start")
        var current = String(readme[start.upperBound..<end.lowerBound])
        if current.hasSuffix("\n") { current.removeLast() }
        XCTAssertEqual(current, Self.table(), "Update the README table to:\n\n\(Self.table())\n")
    }
}
