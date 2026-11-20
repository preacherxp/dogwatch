import SwiftUI

/// The panel: a header, then the dashboard, the logbook or settings.
struct NauticalDashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var page: DashboardPage = .dashboard

    private var design: DashboardDesign { store.config.theme }

    var body: some View {
        content
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(width: Bridge.windowWidth, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(DesignBackdrop(design: design))
            .clipped()
            .preferredColorScheme(design.colorScheme)
            .environment(\.colorScheme, design.colorScheme)
            .accessibilityLabel("Dogwatch")
            .onAppear {
                store.refresh()
            }
    }

    private var content: some View {
        VStack(spacing: Bridge.stack) {
            header
                .padding(.horizontal, Bridge.inset)

            if let message = store.configMessage, page == .dashboard {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(design.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Bridge.inset)
            }

            if page == .settings {
                HarnessSettingsView(store: store, design: design)
                    .padding(.horizontal, Bridge.inset)
            } else if page == .stats {
                UsageStatsView(store: store, design: design)
                    .padding(.horizontal, Bridge.inset)
            } else if design != .nautical {
                DashboardVariantView(
                    design: design,
                    items: store.instruments,
                    activity: store.activity.map { ($0.provider.title, $0.activity) },
                    isLoading: store.isLoading,
                    lastUpdated: store.lastUpdated,
                    refreshMinutes: Int(store.config.refreshInterval / 60)
                )
            } else {
                dashboard
            }
        }
    }

    private var dashboard: some View {
        NauticalPanel(
            items: store.instruments,
            activity: store.activity.map { ($0.provider.title, $0.activity) },
            playIntro: !store.hasPlayedIntro
        )
        .padding(.horizontal, Bridge.inset)
        .onAppear {
            guard !store.hasPlayedIntro else { return }
            DispatchQueue.main.async {
                store.markIntroPlayed()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(design.ink.opacity(0.9))
            }

            Spacer(minLength: 0)

            if page != .settings {
                Button { store.refresh(userInitiated: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(store.isLoading ? .degrees(180) : .zero)
                }
                .buttonStyle(BridgeIconButton(design: design))
                .disabled(store.isLoading)
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")

                Button {
                    withAnimation(Bridge.ease(0.2)) {
                        page = page == .stats ? .dashboard : .stats
                    }
                } label: {
                    Image(systemName: page == .stats ? "xmark" : "chart.xyaxis.line")
                }
                .buttonStyle(BridgeIconButton(design: design))
                .help(page == .stats ? "Close usage history" : "Usage history")
                .accessibilityLabel(page == .stats ? "Close usage history" : "Open usage history")
            }

            Button {
                withAnimation(Bridge.ease(0.2)) {
                    page = page == .settings ? .dashboard : .settings
                }
            } label: {
                Image(systemName: page == .settings ? "xmark" : "gearshape")
            }
            .buttonStyle(BridgeIconButton(design: design))
            .help(page == .settings ? "Close settings" : "Settings")
            .accessibilityLabel(page == .settings ? "Close settings" : "Open settings")
        }
    }
}

private enum DashboardPage {
    case dashboard
    case stats
    case settings
}

/// How a panel lays out its providers: full plates for a few, compact rows for many, a section
/// per category when both kinds are on, and a scroll view past a fixed height.
enum PanelLayout {
    /// More providers than this use compact rows.
    static let fullPlateLimit = 4
    /// More providers than this scroll.
    static let scrollLimit = 8
    static let scrollHeight: CGFloat = 520

    static func isCompact(_ count: Int) -> Bool { count > fullPlateLimit }
    static func scrolls(_ count: Int) -> Bool { count > scrollLimit }

    /// Items grouped by category, in order; one group when only one category is on.
    static func sections(_ items: [BridgeInstrument]) -> [(title: String?, items: [BridgeInstrument])] {
        let categories = ProviderCategory.allCases.filter { category in items.contains { $0.category == category } }
        guard categories.count > 1 else { return [(nil, items)] }
        return categories.map { category in (category.title, items.filter { $0.category == category }) }
    }
}

/// Wraps a panel's list in a scroll view once there are too many providers to fit.
struct PanelScroll<Content: View>: View {
    let count: Int
    @ViewBuilder let content: () -> Content
    @Environment(\.renderingStillImage) private var renderingStillImage

    var body: some View {
        if PanelLayout.scrolls(count) {
            if renderingStillImage {
                // ImageRenderer can't draw a ScrollView, so previews show the visible part.
                content().frame(height: PanelLayout.scrollHeight, alignment: .top).clipped()
            } else {
                ScrollView(.vertical) { content().padding(.bottom, 4) }
                    .frame(height: PanelLayout.scrollHeight)
            }
        } else {
            content()
        }
    }
}

private struct RenderingStillImageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by previews and tests that render with `ImageRenderer`.
    var renderingStillImage: Bool {
        get { self[RenderingStillImageKey.self] }
        set { self[RenderingStillImageKey.self] = newValue }
    }
}

/// One brass gauge per provider, like a row of dials on the bridge.
struct NauticalPanel: View {
    let items: [BridgeInstrument]
    var activity: (title: String, activity: TokenActivity)? = nil
    var playIntro = false

    init(items: [BridgeInstrument], activity: (title: String, activity: TokenActivity)? = nil, playIntro: Bool = false) {
        self.items = items
        self.activity = activity
        self.playIntro = playIntro
    }

    /// Codex's parsed snapshot as the token card, as the panel was first written.
    init(items: [BridgeInstrument], snapshot: UsageSnapshot?, playIntro: Bool = false) {
        self.init(items: items, activity: snapshot.map { ("Codex", $0.activity) }, playIntro: playIntro)
    }

    var body: some View {
        PanelScroll(count: items.count) {
            VStack(spacing: 12) {
                ForEach(Array(PanelLayout.sections(items).enumerated()), id: \.offset) { _, section in
                    if let title = section.title {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Bridge.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(section.items) { item in
                        if PanelLayout.isCompact(items.count) { compactRow(item) } else { gaugePlate(item) }
                    }
                }

                if let activity {
                    tokenPlate(activity.title, activity.activity)
                }
            }
        }
    }

    private func gaugePlate(_ item: BridgeInstrument) -> some View {
        HStack(spacing: 16) {
            AnalogGauge(remaining: item.remaining, tint: item.provider.tint, size: 104, playIntro: playIntro,
                        figure: item.displayPercent, caption: item.amount == nil ? item.percentCaption : item.amountCaption,
                        amount: item.amount, warningThreshold: item.warningThreshold)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Bridge.cream)
                    Text(item.secondaryLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Bridge.secondaryText)
                        .lineLimit(1)
                }
                Text(item.isWarning ? "Running low · \(item.detail)" : item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isWarning || item.state == .failed ? Bridge.coral : Bridge.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if item.resetDate != nil {
                    Text(resetText(item.resetDate))
                        .font(.system(size: 12))
                        .foregroundStyle(Bridge.muted)
                        .help(UsageFormatters.reset(item.resetDate))
                }
                ForEach(item.meters) { meter in
                    HStack(spacing: 8) {
                        Text(meter.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Bridge.secondaryText)
                            .lineLimit(1)
                        TickedMeter(value: meter.remaining, tint: meter.remaining <= item.warningThreshold ? Bridge.coral : item.provider.tint)
                        figure(meter.remaining, size: 12, threshold: item.warningThreshold)
                    }
                    .padding(.top, 8)
                }
                ForEach(item.notes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Bridge.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .instrumentPlate(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PanelText.accessibilityLabel(for: item))
    }

    /// One line per provider when there are many: a small dial, the name and detail, the value.
    private func compactRow(_ item: BridgeInstrument) -> some View {
        HStack(spacing: 12) {
            AnalogGauge(remaining: item.amount == nil ? item.remaining : nil, tint: item.provider.tint, size: 40,
                        figure: item.displayPercent, caption: item.percentCaption, warningThreshold: item.warningThreshold)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Bridge.cream)
                        .lineLimit(1)
                    Text(item.secondaryLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Bridge.secondaryText)
                        .lineLimit(1)
                }
                Text(item.isWarning ? "Running low · \(item.detail)" : item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(item.isWarning || item.state == .failed ? Bridge.coral : Bridge.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(PanelText.value(item))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(item.isWarning ? Bridge.coral : Bridge.cream)
                .lineLimit(1)
        }
        .instrumentPlate(padding: 10)
        .help(item.notes.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PanelText.accessibilityLabel(for: item))
    }

    private func tokenPlate(_ title: String, _ activity: TokenActivity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(title) tokens")
                    .foregroundStyle(Bridge.secondaryText)
                Spacer()
                Text("Last 7 days")
                    .foregroundStyle(Bridge.muted)
            }
            .font(.system(size: 12))
            HStack(spacing: 0) {
                stat("Today", UsageFormatters.tokens(activity.tokensToday))
                stat("All time", UsageFormatters.tokens(activity.lifetimeTokens))
                stat("Credits", UsageFormatters.credits(activity.credits))
            }
            TideChart(days: activity.lastSevenDays, highlight: Bridge.seafoam)
                .frame(height: 64)
        }
        .instrumentPlate(padding: 16)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Bridge.secondaryText)
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Bridge.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func figure(_ value: Int, size: CGFloat, threshold: Int) -> some View {
        Text("\(value)%")
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(value <= threshold ? Bridge.coral : Bridge.cream)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date, date > Date() else { return UsageFormatters.resetCompact(date) }
        return "Resets \(UsageFormatters.resetCompact(date))"
    }
}

/// Text every design shows the same way.
enum PanelText {
    /// The value at the end of a row: "76%", "24% used", "$12.40", "—".
    static func value(_ item: BridgeInstrument) -> String {
        if let amount = item.amount { return amount }
        guard let percent = item.displayPercent else { return "—" }
        return item.showsUsed ? "\(percent)% used" : "\(percent)%"
    }

    static func accessibilityLabel(for item: BridgeInstrument) -> String {
        let main: String
        if let amount = item.amount {
            main = "\(amount) \(item.amountCaption)"
        } else if let percent = item.remaining {
            main = "\(percent) percent remaining"
        } else {
            main = item.detail
        }
        let meters = item.meters.map { ", \($0.label) \($0.remaining) percent remaining" }.joined()
        return "\(item.title), \(main)\(meters)"
    }
}

/// A flat meter over a dial scale, the same tick marks the gauge carries.
struct TickedMeter: View {
    let value: Int
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Bridge.cream.opacity(0.08)
                    tint.frame(width: geometry.size.width * CGFloat(value) / 100)
                }
            }
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 2))

            Canvas { context, size in
                var ticks = Path()
                for index in 0...20 {
                    let x = min(max(size.width * CGFloat(index) / 20, 0.5), size.width - 0.5)
                    let height: CGFloat = index % 10 == 0 ? 4 : index % 2 == 0 ? 3 : 1.5
                    ticks.move(to: CGPoint(x: x, y: 0))
                    ticks.addLine(to: CGPoint(x: x, y: height))
                }
                context.stroke(ticks, with: .color(Bridge.cream.opacity(0.22)), lineWidth: 1)
            }
            .frame(height: 4)
        }
        .accessibilityHidden(true)
    }
}

struct AnalogGauge: View {
    /// Percentage left; drives the arc.
    let remaining: Int?
    let tint: Color
    let size: CGFloat
    var playIntro = false
    /// The figure in the middle, when it differs from `remaining` (percentage used).
    var figure: Int? = nil
    var caption = "left"
    /// An amount instead of a percentage: no arc, the amount in the middle.
    var amount: String? = nil
    var warningThreshold = 20

    @State private var displayed: Double
    @State private var didPlayIntro = false

    init(remaining: Int?, tint: Color, size: CGFloat, playIntro: Bool = false, figure: Int? = nil, caption: String = "left", amount: String? = nil, warningThreshold: Int = 20) {
        self.remaining = remaining
        self.tint = tint
        self.size = size
        self.playIntro = playIntro
        self.figure = figure
        self.caption = caption
        self.amount = amount
        self.warningThreshold = warningThreshold
        _displayed = State(initialValue: playIntro ? 0 : Double(remaining ?? 0) / 100)
    }

    private var fraction: Double {
        Double(remaining ?? 0) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Bridge.deep)
            Circle()
                .stroke(Bridge.brass.opacity(0.5), lineWidth: 1.5)

            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Bridge.cream.opacity(0.08), style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(arcInset)

            Circle()
                .trim(from: 0, to: 0.75 * displayed)
                .stroke(tint, style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(arcInset)

            GaugeTicks(majorCount: 5, minorCount: 20)
                .stroke(Bridge.cream.opacity(0.22), lineWidth: 1)
                .padding(size * 0.035)

            Circle()
                .fill(Bridge.well)
                .frame(width: wellSize, height: wellSize)
                .overlay(Circle().stroke(Bridge.brass.opacity(0.3), lineWidth: 1))

            VStack(spacing: 0) {
                if let amount {
                    Text(amount)
                        .font(.system(size: size * 0.15, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: wellSize * 0.9)
                        .foregroundStyle(Bridge.cream)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text((figure ?? remaining).map(String.init) ?? "—")
                            .font(.system(size: size * 0.22, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                        if remaining != nil, size >= 60 {
                            Text("%")
                                .font(.system(size: size * 0.1, weight: .medium, design: .monospaced))
                        }
                    }
                    .foregroundStyle((remaining ?? 100) <= warningThreshold ? Bridge.coral : Bridge.cream)
                }
                if size >= 60 {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Bridge.secondaryText)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if playIntro, !didPlayIntro {
                didPlayIntro = true
                displayed = 0
                withAnimation(Bridge.ease(0.8)) {
                    displayed = fraction
                }
            } else {
                displayed = fraction
            }
        }
        .onChange(of: remaining) { newValue in
            withAnimation(Bridge.ease(0.5)) {
                displayed = Double(newValue ?? 0) / 100
            }
        }
    }

    private var arcWidth: CGFloat { size * 0.055 }
    private var arcInset: CGFloat { size * 0.13 }
    private var wellSize: CGFloat { size * 0.56 }
}

private struct GaugeTicks: Shape {
    let majorCount: Int
    let minorCount: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2

        for index in 0...minorCount {
            let fraction = Double(index) / Double(minorCount)
            let angle = Angle.degrees(135 + 270 * fraction).radians
            let isMajor = index % (minorCount / max(1, majorCount - 1)) == 0
            let inner = outer - (isMajor ? 8 : 4)
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}

struct TideChart: View {
    let days: [DailyUsage]
    let highlight: Color

    private var maximum: Double {
        max(1, Double(days.map(\.tokens).max() ?? 1))
    }

    var body: some View {
        VStack(spacing: Bridge.tight) {
            GeometryReader { geo in
                let points = tidePoints(in: geo.size)
                ZStack {
                    Path { path in
                        guard let first = points.first, let last = points.last else { return }
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        path.addLine(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(Bridge.cream.opacity(0.05))

                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(Bridge.cream.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        if Calendar.current.isDateInToday(day.date), index < points.count {
                            Circle()
                                .fill(highlight)
                                .frame(width: 6, height: 6)
                                .position(points[index])
                        }
                    }
                }
            }
            .frame(height: 44)

            HStack {
                ForEach(days) { day in
                    let isToday = Calendar.current.isDateInToday(day.date)
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 11, weight: isToday ? .medium : .regular))
                        .foregroundStyle(isToday ? Bridge.cream : Bridge.muted)
                        .frame(maxWidth: .infinity)
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.tokens.formatted()) tokens")
                }
            }
        }
    }

    private func tidePoints(in size: CGSize) -> [CGPoint] {
        guard !days.isEmpty else { return [] }
        return days.enumerated().map { index, day in
            let inset: CGFloat = 4
            let usable = max(size.width - inset * 2, 1)
            let x = inset + usable * CGFloat(index) / CGFloat(max(days.count - 1, 1))
            let y = size.height - size.height * CGFloat(Double(day.tokens) / maximum)
            return CGPoint(x: x, y: y)
        }
    }
}
