import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Dogwatch

/// Rules every registered provider must follow, and proof that the rules catch a provider that
/// breaks them.
final class ProviderContractTests: XCTestCase {
    func testEveryRegisteredProviderFollowsTheRules() {
        for provider in ProviderRegistry.builtIn {
            assertFollowsRules(provider)
        }
    }

    func testRegistryIsSortedByIDWithoutDuplicates() {
        let ids = ProviderRegistry.builtIn.map(\.id.rawValue)
        XCTAssertEqual(ids, ids.sorted(), "Keep ProviderRegistry.builtIn sorted by id so additions merge cleanly.")
        XCTAssertEqual(Set(ids).count, ids.count, "Provider ids must be unique.")
    }

    func testNoTwoProvidersLookAlikeInAList() {
        var glyphs: [String: ProviderID] = [:]
        var tints: [String: ProviderID] = [:]
        for provider in ProviderRegistry.builtIn {
            let descriptor = provider.descriptor
            if let other = glyphs[descriptor.glyph.symbol] {
                XCTFail("\(descriptor.id) and \(other) both use the glyph \(descriptor.glyph.symbol).")
            }
            glyphs[descriptor.glyph.symbol] = descriptor.id
            let color = NSColor(descriptor.tint).usingColorSpace(.sRGB)!
            let tint = String(format: "%.2f %.2f %.2f", color.redComponent, color.greenComponent, color.blueComponent)
            if let other = tints[tint] { XCTFail("\(descriptor.id) and \(other) both use the tint \(tint).") }
            tints[tint] = descriptor.id
        }
    }

    func testDefaultEnabledProvidersAreRegistered() {
        let ids = Set(ProviderRegistry.builtIn.map(\.id))
        for id in ProviderRegistry.defaultEnabled { XCTAssertTrue(ids.contains(id), id.rawValue) }
    }

    func testOnlyProvidersThatStartAProgramDeclareOne() {
        for provider in ProviderRegistry.builtIn {
            for command in provider.descriptor.commands {
                XCTAssertFalse(command.reason.isEmpty, provider.id.rawValue)
            }
        }
        XCTAssertEqual(GrokProvider().descriptor.commands, [], "Grok must never start the Grok CLI.")
    }

    // MARK: The rules catch bad providers

    private func descriptor(
        credential: CredentialRequirement = .none,
        stability: ProviderStability = .unverified,
        localSources: [ToolStore] = [],
        commands: [DeclaredCommand] = [],
        hosts: [String] = ["api.example.com"]
    ) -> ProviderDescriptor {
        ProviderDescriptor(
            id: "bad", name: "Bad", glyph: ProviderGlyph(symbol: "circle"), tint: .gray, category: .api,
            stability: stability, credential: credential, summary: "", reads: "Reads a thing from somewhere, for testing.",
            source: "Tests", allowedHosts: hosts, localSources: localSources, commands: commands
        )
    }

    func testRejectsAWriteToAnotherToolsFiles() {
        let bad = descriptor(localSources: [ToolStore(kind: .file, location: "~/.tool/auth.json", access: .readWrite)])
        XCTAssertFalse(ProviderContract.violations(of: bad).isEmpty)
    }

    func testRejectsACommandThatTouchesASignIn() {
        let bad = descriptor(commands: [DeclaredCommand(executable: "tool", arguments: ["auth", "refresh"], reason: "Refreshes the login.")])
        XCTAssertFalse(ProviderContract.violations(of: bad).isEmpty)
    }

    func testRejectsADocumentedLabelOnAnUndocumentedCommand() {
        let bad = descriptor(stability: .documented, commands: [DeclaredCommand(executable: "tool", arguments: ["usage"], reason: "Reads usage.")])
        XCTAssertFalse(ProviderContract.violations(of: bad).isEmpty)
        let fine = descriptor(stability: .documented, commands: [DeclaredCommand(executable: "tool", arguments: ["usage"], reason: "Reads usage.", documentedReadOnly: true)])
        XCTAssertTrue(ProviderContract.violations(of: fine).isEmpty, ProviderContract.violations(of: fine).joined())
    }

    func testRejectsAPastedKeyWithoutDeclaredHosts() {
        let bad = descriptor(credential: .pastedKey(KeySpec(label: "API key", placeholder: "", helpURL: nil)), hosts: [])
        XCTAssertFalse(ProviderContract.violations(of: bad).isEmpty)
    }

    func testFlagsUndeclaredHostsRefreshesAndKeysOutsideHeaders() {
        let declared = descriptor()
        var refresh = URLRequest(url: URL(string: "https://auth.example.com/oauth/token")!)
        refresh.httpBody = Data("grant_type=refresh_token".utf8)
        let keyInURL = URLRequest(url: URL(string: "https://api.example.com/v1/usage?key=secret-key")!)
        let problems = ProviderContract.violations(in: [refresh, keyInURL], descriptor: declared, key: "secret-key")
        XCTAssertTrue(problems.contains { $0.contains("undeclared host") })
        XCTAssertTrue(problems.contains { $0.contains("sign-in endpoint") })
        XCTAssertTrue(problems.contains { $0.contains("refresh") })
        XCTAssertTrue(problems.contains { $0.contains("key in the URL") })
    }

    func testTheHTTPClientRefusesUndeclaredHostsAndPlainHTTP() async {
        let transport = FixtureTransport()
        let client = HTTPClient(allowedHosts: ["api.example.com"], transport: transport)
        for url in ["https://evil.example.org/x", "http://api.example.com/x", "ftp://api.example.com/x"] {
            do {
                _ = try await client.get(URL(string: url)!)
                XCTFail("\(url) should be refused")
            } catch let error as ProviderError {
                XCTAssertEqual(error.kind, "hostNotAllowed", url)
            } catch {
                XCTFail("\(error)")
            }
        }
        XCTAssertTrue(transport.requests.isEmpty, "Nothing may be sent to a refused host.")
        let local = HTTPClient(allowedHosts: ["localhost"], transport: transport)
        transport.respond(to: "http://localhost:4000", body: Data("{}".utf8))
        let data = try? await local.get(URL(string: "http://localhost:4000/key/info")!)
        XCTAssertNotNil(data, "Plain HTTP is allowed on localhost for self-hosted gateways.")
    }

    func testTheCommandGateRunsOnlyDeclaredCommands() {
        let declared = DeclaredCommand(executable: "ls", arguments: ["-1"], reason: "Lists.", documentedReadOnly: true)
        let tools = LocalTools(environment: ["PATH": "/bin:/usr/bin"], gate: DeclaredCommandGate(declared: [declared]))
        XCTAssertNoThrow(try tools.authorize(declared))
        XCTAssertThrowsError(try tools.authorize(DeclaredCommand(executable: "ls", arguments: ["-la"], reason: "Lists."))) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "commandNotAllowed")
        }
    }
}
