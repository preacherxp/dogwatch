import AppKit
import SwiftUI
import XCTest
@testable import Dogwatch

/// Claude, Codex and Grok report whichever windows the subscription has. These cover the
/// shapes seen from the Claude usage endpoint, including `"five_hour": null` for a plan
/// without a five-hour limit.
final class UsageWindowTests: XCTestCase {
    private let future = Date().addingTimeInterval(3 * 86_400)
    private let soon = Date().addingTimeInterval(2 * 3_600)
    private let past = Date().addingTimeInterval(-3_600)

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func api(_ json: String) throws -> ClaudeUsageSnapshot {
        try ClaudeUsageClient.parseUsage(Data(json.utf8), fetchedAt: Date())
    }

    private var weekly: String { #""seven_day": {"utilization": 79, "resets_at": "\#(iso(future))"}"# }

    // MARK: Five-hour window present

    func testFiveHourActive() throws {
        let claude = try api(#"{"five_hour": {"utilization": 27.4, "resets_at": "\#(iso(soon))"}, \#(weekly)}"#)
        let item = BridgeLayout.claudeInstrument(claude, error: nil)

        XCTAssertEqual(claude.mainWindow, .fiveHour)
        XCTAssertEqual(item.remaining, 73)
        XCTAssertEqual(item.detail, "27% used · 5h")
        XCTAssertEqual(item.secondaryLabel, "5h session")
        XCTAssertEqual(item.resetDate?.timeIntervalSince1970 ?? 0, soon.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(item.weeklyRemaining, 21)
        XCTAssertEqual(claude.lowestRemainingPercent, 21)
    }

    func testFiveHourPresentButNotStarted() throws {
        let claude = try api(#"{"five_hour": {"utilization": null, "resets_at": null}, \#(weekly)}"#)
        let item = BridgeLayout.claudeInstrument(claude, error: nil)

        XCTAssertTrue(claude.hasFiveHourWindow)
        XCTAssertEqual(item.remaining, 100)
        XCTAssertEqual(item.detail, "New 5h window · starts with your next message")
        XCTAssertNil(item.resetDate)
        XCTAssertEqual(item.secondaryLabel, "5h session")
        XCTAssertEqual(item.weeklyRemaining, 21)
        XCTAssertEqual(claude.lowestRemainingPercent, 21, "The menu bar shows the tighter window")
    }

    func testFiveHourExpired() throws {
        let claude = try api(#"{"five_hour": {"utilization": 90, "resets_at": "\#(iso(past))"}, \#(weekly)}"#)
        let item = BridgeLayout.claudeInstrument(claude, error: nil)

        XCTAssertEqual(item.remaining, 100)
        XCTAssertEqual(item.detail, "New 5h window · starts with your next message")
        XCTAssertEqual(item.weeklyRemaining, 21)
    }

    func testFiveHourActiveAndTighterThanWeekIsTheMenuBarValue() throws {
        let claude = try api(#"{"five_hour": {"utilization": 96, "resets_at": "\#(iso(soon))"}, \#(weekly)}"#)

        XCTAssertEqual(claude.lowestRemainingPercent, 4)
        XCTAssertTrue(BridgeLayout.claudeInstrument(claude, error: nil).isWarning)
    }

    // MARK: No five-hour limit

    func testNoFiveHourLimitShowsTheWeek() throws {
        for json in [#"{"five_hour": null, \#(weekly), "seven_day_opus": null}"#, #"{\#(weekly)}"#] {
            let claude = try api(json)
            let item = BridgeLayout.claudeInstrument(claude, error: nil)

            XCTAssertFalse(claude.hasFiveHourWindow, json)
            XCTAssertEqual(claude.mainWindow, .weekly)
            XCTAssertEqual(item.remaining, 21)
            XCTAssertEqual(item.detail, "79% used · weekly")
            XCTAssertEqual(item.secondaryLabel, "weekly")
            XCTAssertEqual(item.resetDate?.timeIntervalSince1970 ?? 0, future.timeIntervalSince1970, accuracy: 1)
            XCTAssertNil(item.weeklyRemaining, "No Week meter repeating the gauge")
            XCTAssertEqual(claude.lowestRemainingPercent, 21)
        }
    }

    func testWeeklyOnlyRunningLow() throws {
        let claude = try api(#"{"five_hour": null, "seven_day": {"utilization": 85, "resets_at": "\#(iso(future))"}}"#)
        let item = BridgeLayout.claudeInstrument(claude, error: nil)

        XCTAssertTrue(item.isWarning)
        XCTAssertEqual(item.detail, "85% used · weekly")
    }

    func testStatusLineWithOnlyTheWeek() throws {
        let data = Data(#"{"seven_day": {"used_percentage": 41, "resets_at": \#(Int(future.timeIntervalSince1970))}}"#.utf8)
        let claude = try ClaudeUsageClient.parseStatusLineCache(data, modifiedAt: Date())
        let item = BridgeLayout.claudeInstrument(claude, error: nil)

        XCTAssertEqual(claude.mainWindow, .weekly)
        XCTAssertEqual(item.remaining, 59)
        XCTAssertEqual(item.secondaryLabel, "weekly")
        XCTAssertEqual(claude.lowestRemainingPercent, 59)
    }

    // MARK: Neither window

    func testNeitherWindowShowsNoReading() throws {
        for json in [#"{"five_hour": null, "seven_day": null}"#, "{}"] {
            let claude = try api(json)
            let item = BridgeLayout.claudeInstrument(claude, error: nil)

            XCTAssertNil(claude.mainWindow)
            XCTAssertNil(item.remaining, json)
            XCTAssertNil(claude.weeklyRemainingPercent)
            XCTAssertNil(claude.lowestRemainingPercent)
            XCTAssertEqual(item.detail, "No usage window reported")
        }
        XCTAssertNil(BridgeLayout.claudeInstrument(nil, error: nil).remaining)
        XCTAssertEqual(BridgeLayout.claudeInstrument(nil, error: "Signed out").detail, "Signed out")
    }

    // MARK: History

    func testHistoryKeepsTheWeeklyPercentageWhenTheFiveHourWindowGoesAway() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try UsageHistoryDatabase(url: directory.appendingPathComponent("history.sqlite3"))
        let morning = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3_600)

        let withFiveHour = try api(#"{"five_hour": {"utilization": 60, "resets_at": "\#(iso(soon))"}, "seven_day": {"utilization": 70, "resets_at": "\#(iso(future))"}}"#)
        try database.record(codex: nil, claude: withFiveHour, grok: nil, observedAt: morning)
        let weeklyOnly = try api(#"{"five_hour": null, "seven_day": {"utilization": 74, "resets_at": "\#(iso(future))"}}"#)
        try database.record(codex: nil, claude: weeklyOnly, grok: nil, observedAt: morning.addingTimeInterval(3_600))
        let neither = try api("{}")
        try database.record(codex: nil, claude: neither, grok: nil, observedAt: morning.addingTimeInterval(7_200))

        let rows = try database.entries(in: .sevenDays, now: morning.addingTimeInterval(7_200))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.provider, .claude)
        XCTAssertEqual(rows.first?.usedPercent, 74, "The weekly percentage, never the five-hour one")
    }

    // MARK: Codex without a short window

    func testCodexWithoutPrimaryUsesTheSecondaryWindow() throws {
        let rateLimits: [String: Any] = ["rateLimits": [
            "secondary": ["usedPercent": 40, "windowDurationMins": 10_080],
            "planType": "plus"
        ]]
        let snapshot = try CodexUsageClient.parse(rateLimits: rateLimits, tokenUsage: ["summary": [:], "dailyUsageBuckets": []])

        XCTAssertEqual(snapshot.remainingPercent, 60)
        XCTAssertEqual(snapshot.windowLabel, "weekly")
        XCTAssertNil(snapshot.weeklyRemainingPercent, "No second meter repeating the gauge")
    }

    func testCodexWithNoWindowIsAnErrorNotFullAllowance() {
        XCTAssertThrowsError(try CodexUsageClient.parse(
            rateLimits: ["rateLimits": ["planType": "plus"]],
            tokenUsage: ["summary": [:], "dailyUsageBuckets": []]
        ))
    }

    func testWindowLabelComesFromTheReportedDuration() {
        func label(_ minutes: Int?) -> String {
            UsageSnapshot(planName: "Plus", usedPercent: 0, resetDate: nil, windowMinutes: minutes,
                          lifetimeTokens: nil, dailyUsage: [], creditBalance: nil).windowLabel
        }
        XCTAssertEqual(label(300), "5h")
        XCTAssertEqual(label(1_440), "24h")
        XCTAssertEqual(label(10_080), "weekly")
        XCTAssertEqual(label(30), "30m")
        XCTAssertEqual(label(nil), "current window")
    }

    // MARK: Preview

    @MainActor
    func testWeeklyOnlyClaudeRendersInEveryDesign() throws {
        let claude = try api(#"{"five_hour": null, "seven_day": {"utilization": 79, "resets_at": "\#(iso(future))"}}"#)
        let items = [
            BridgeInstrument(provider: .codex, remaining: 76, detail: "24% used · weekly", resetDate: future, secondaryLabel: "Pro"),
            BridgeLayout.claudeInstrument(claude, error: nil),
            BridgeInstrument(provider: .grok, remaining: 61, detail: "39% used · weekly", resetDate: future, secondaryLabel: "Grok")
        ]
        for design in DashboardDesign.allCases {
            let panel = design == .nautical
                ? AnyView(NauticalPanel(items: items, snapshot: nil).padding(.horizontal, Bridge.inset))
                : AnyView(DashboardVariantView(design: design, items: items, snapshot: nil, isLoading: false, lastUpdated: Date()))
            let renderer = ImageRenderer(content: panel
                .padding(.vertical, 16)
                .frame(width: Bridge.windowWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesignBackdrop(design: design))
                .environment(\.colorScheme, design.colorScheme))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, design.title)
            XCTAssertEqual(image.width, Int(Bridge.windowWidth * 2))
            XCTAssertGreaterThan(image.height, 200)
            if let directory = ProcessInfo.processInfo.environment["DOGWATCH_DESIGN_PREVIEWS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("\(design.rawValue)-claude-weekly-only.png"))
            }
        }
    }
}
