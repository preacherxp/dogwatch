import SwiftUI

struct UsageStatsView: View {
    @ObservedObject var store: UsageStore
    var design: DashboardDesign = .nautical
    @State private var metric: UsageStatsMetric = .allowance
    /// Providers the user filtered out; everything else switched on is shown.
    @State private var deselected = Set<ProviderID>()

    private var visibleHarnesses: [ProviderID] {
        store.enabledProviders
    }

    private var selectedHarnesses: Set<ProviderID> {
        Set(visibleHarnesses).subtracting(deselected)
    }

    private var filteredEntries: [UsageHistoryEntry] {
        store.historyEntries.filter { selectedHarnesses.contains($0.provider) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: design.spacing) {
            title
            metricPicker
            filterBar

            if let error = store.historyErrorMessage, store.historyEntries.isEmpty {
                errorState(error)
            } else if filteredEntries.isEmpty {
                emptyState
            } else {
                summary
                chart
                recentEntries
                accuracyNote
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        if design == .nautical {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage logbook")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(design.ink)
                Spacer()
                if let lastUpdated = store.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12))
                        .foregroundStyle(Bridge.muted)
                }
            }
        } else {
            DesignHeading(design: design, eyebrow: "Activity / usage history",
                title: design == .ledger ? "The collected work" : "HISTORY /",
                subtitle: store.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" })
        }
    }

    private var metricPicker: some View {
        DesignSegmentedPicker(design: design, options: UsageStatsMetric.allCases, title: { design.label($0.title) }, selection: $metric)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(UsageHistoryRange.allCases) { range in
                filterButton(range.compactTitle, isSelected: store.historyRange == range) {
                    store.setHistoryRange(range)
                }
            }

            Spacer(minLength: 4)

            Menu {
                ForEach(visibleHarnesses) { harness in
                    Button {
                        toggleHarness(harness)
                    } label: {
                        Label(
                            harness.title,
                            systemImage: selectedHarnesses.contains(harness) ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(platformFilterTitle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: design.textSize(7), weight: .bold))
                }
                .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                .foregroundStyle(design.ink.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: design.controlRadius))
                .background(design.surface, in: RoundedRectangle(cornerRadius: design.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: design.controlRadius).stroke(design.border, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(design.ink)
            .accessibilityLabel("Filter providers")
            .fixedSize()
        }
    }

    private var summary: some View {
        HStack(spacing: Bridge.stack) {
            ForEach(selectedVisibleHarnesses) { harness in
                VStack(alignment: .leading, spacing: 2) {
                    Text(design.label(harness.title))
                        .font(.system(size: design.textSize(7), weight: design.labelWeight, design: design.bodyFont))
                        .tracking(design.tracking(0.8))
                        .foregroundStyle(design.secondary)
                    Text(summaryValue(for: harness))
                        .font(.system(size: design == .ledger ? 28 : design.textSize(17), weight: design == .ledger ? .regular : design == .nautical ? .medium : .bold, design: design.numberFont))
                        .monospacedDigit()
                        .foregroundStyle(design.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text(design.label(metric.summaryLabel))
                        .font(.system(size: design.textSize(6), weight: design == .cyber ? .semibold : .regular, design: design.bodyFont))
                        .tracking(design.tracking(0.6))
                        .foregroundStyle(design.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .instrumentPlate(design: design)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(design.label(metric.chartTitle))
                    .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                    .tracking(design.tracking(1.2))
                    .foregroundStyle(design.secondary)
                Spacer()
                Text(design.label(dateRangeLabel))
                    .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                    .foregroundStyle(design.ink)
            }

            UsageHistoryChart(
                entries: filteredEntries,
                harnesses: selectedVisibleHarnesses,
                metric: metric,
                range: store.historyRange,
                design: design
            )
            .frame(height: 132)

            HStack(spacing: 12) {
                ForEach(selectedVisibleHarnesses) { harness in
                    HStack(spacing: 4) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 1))
                            path.addLine(to: CGPoint(x: 16, y: 1))
                        }
                        .stroke(design.accent(for: harness), style: StrokeStyle(lineWidth: 1.5, dash: design.lineDash(for: harness)))
                        .frame(width: 16, height: 2)
                        Text(design.label(harness.title))
                            .font(.system(size: design.textSize(7), weight: design.labelWeight, design: design.bodyFont))
                            .foregroundStyle(design.secondary)
                    }
                }
            }
        }
        .instrumentPlate(design: design)
    }

    private var recentEntries: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(design.label("Recent entries"))
                    .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                    .tracking(design.tracking(1.2))
                    .foregroundStyle(design.secondary)
                Spacer()
                Text(design.label(metric.tableUnit))
                    .font(.system(size: design.textSize(7), weight: design.labelWeight, design: design.bodyFont))
                    .foregroundStyle(design.ink)
            }
            .padding(.bottom, 4)

            ForEach(recentDates, id: \.self) { date in
                HStack(spacing: 4) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                        .foregroundStyle(design.secondary)
                        .frame(width: 52, alignment: .leading)

                    ForEach(selectedVisibleHarnesses) { harness in
                        Text(value(on: date, for: harness))
                            .font(.system(size: design.textSize(9), weight: design == .cyber ? .bold : design == .ledger ? .regular : .medium, design: design.numberFont))
                            .monospacedDigit()
                            .foregroundStyle(design.ink)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help("\(harness.title) · \(date.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .frame(height: 27)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(design.border.opacity(0.5))
                        .frame(height: 1)
                }
            }
        }
        .instrumentPlate(design: design)
    }

    private var accuracyNote: some View {
        Text(metric == .tokens
            ? "Exact token totals appear only where a platform reports them"
            : "Allowance is the latest used percentage observed on each day")
            .font(.system(size: design.textSize(8), weight: .medium, design: design.bodyFont))
            .foregroundStyle(design.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        VStack(spacing: Bridge.stack) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 26))
                .foregroundStyle(design.accent(for: .codex))
            Text(design.label(design == .nautical ? "The logbook is empty" : "No history yet"))
                .font(.system(size: design.textSize(10), weight: design.labelWeight, design: design.bodyFont))
                .tracking(design.tracking(1.2))
                .foregroundStyle(design.ink)
            Text("Refresh usage to record the first daily entry")
                .font(.system(size: design.textSize(10), design: design.headingFont))
                .foregroundStyle(design.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .instrumentPlate(design: design)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Bridge.stack) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 25))
                .foregroundStyle(design.warning)
            Text(design.label(design == .nautical ? "Logbook unavailable" : "History unavailable"))
                .font(.system(size: design.textSize(10), weight: design.labelWeight, design: design.bodyFont))
                .foregroundStyle(design.ink)
            Text(message)
                .font(.system(size: design.textSize(9), design: design.bodyFont))
                .multilineTextAlignment(.center)
                .foregroundStyle(design.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .instrumentPlate(design: design)
    }

    private func filterButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                .foregroundStyle(isSelected ? design.selectionInk : design.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: design.controlRadius))
                .background(isSelected ? design.selectionFill : design.surface, in: RoundedRectangle(cornerRadius: design.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: design.controlRadius).stroke(isSelected ? design.ink.opacity(0.55) : design.border))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedVisibleHarnesses: [ProviderID] {
        visibleHarnesses.filter { selectedHarnesses.contains($0) }
    }

    private var platformFilterTitle: String {
        design.label(selectedVisibleHarnesses.count == visibleHarnesses.count
            ? "All platforms"
            : "\(selectedVisibleHarnesses.count) platform\(selectedVisibleHarnesses.count == 1 ? "" : "s")")
    }

    private var dateRangeLabel: String {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(store.historyRange.rawValue - 1), to: end) ?? end
        return "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var recentDates: [Date] {
        let calendar = Calendar.current
        let dates = Set(filteredEntries.map { calendar.startOfDay(for: $0.date) })
        return dates.sorted(by: >).prefix(3).map { $0 }
    }

    private func toggleHarness(_ harness: ProviderID) {
        if selectedHarnesses.contains(harness) {
            guard selectedVisibleHarnesses.count > 1 else { return }
            deselected.insert(harness)
        } else {
            deselected.remove(harness)
        }
    }

    private func summaryValue(for harness: ProviderID) -> String {
        let entries = filteredEntries.filter { $0.provider == harness }
        switch metric {
        case .allowance:
            return entries.last(where: { $0.usedPercent != nil })?.usedPercent.map { "\($0)%" } ?? "—"
        case .tokens:
            let values = entries.compactMap(\.tokens)
            guard !values.isEmpty else { return "—" }
            return UsageFormatters.tokens(values.reduce(0, +))
        }
    }

    private func value(on date: Date, for harness: ProviderID) -> String {
        guard let entry = filteredEntries.first(where: {
            $0.provider == harness && Calendar.current.isDate($0.date, inSameDayAs: date)
        }) else { return "—" }

        switch metric {
        case .allowance:
            return entry.usedPercent.map { "\($0)%" } ?? "—"
        case .tokens:
            return entry.tokens.map { UsageFormatters.tokens($0) } ?? "—"
        }
    }
}

private enum UsageStatsMetric: String, CaseIterable, Identifiable {
    case allowance
    case tokens

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var summaryLabel: String {
        switch self {
        case .allowance: return "Latest used"
        case .tokens: return "Period total"
        }
    }

    var chartTitle: String {
        switch self {
        case .allowance: return "Daily allowance used"
        case .tokens: return "Exact daily tokens"
        }
    }

    var tableUnit: String {
        switch self {
        case .allowance: return "Percent used"
        case .tokens: return "Tokens"
        }
    }
}

private struct UsageHistoryChart: View {
    let entries: [UsageHistoryEntry]
    let harnesses: [ProviderID]
    let metric: UsageStatsMetric
    let range: UsageHistoryRange
    let design: DashboardDesign

    private var calendar: Calendar { .current }

    private var startDate: Date {
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: today) ?? today
    }

    private var maximum: Double {
        switch metric {
        case .allowance:
            return 100
        case .tokens:
            return max(1, Double(entries.compactMap(\.tokens).max() ?? 1))
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                axis
                plot
            }

            HStack {
                Text(startDate.formatted(.dateTime.month(.abbreviated).day()))
                Spacer()
                Text(design.label("Today"))
            }
            .font(.system(size: design.textSize(7), weight: design.labelWeight, design: design.bodyFont))
            .foregroundStyle(design.secondary)
            .padding(.leading, axisWidth + 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.chartTitle), \(range.rawValue) day chart")
    }

    private var axisWidth: CGFloat { 32 }

    private var axis: some View {
        VStack(alignment: .trailing) {
            Text(axisLabel(for: 1))
            Spacer()
            Text(axisLabel(for: 0.5))
            Spacer()
            Text(axisLabel(for: 0))
        }
        .font(.system(size: design.textSize(6), weight: design == .cyber ? .semibold : .regular, design: design.bodyFont))
        .monospacedDigit()
        .foregroundStyle(design.secondary)
        .frame(width: axisWidth, alignment: .trailing)
        .padding(.vertical, -6)
    }

    private var plot: some View {
        GeometryReader { geometry in
            ZStack {
                grid(in: geometry.size)
                ForEach(harnesses) { harness in
                    line(for: harness, in: geometry.size)
                        .stroke(
                            design.accent(for: harness),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: design.lineDash(for: harness))
                        )
                }
            }
        }
    }

    private func grid(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                let fraction = CGFloat(index) / 2
                Rectangle()
                    .fill(design.border.opacity(0.5))
                    .frame(height: 1)
                    .offset(y: fraction * max(0, size.height - 1))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func line(for harness: ProviderID, in size: CGSize) -> Path {
        let harnessEntries = entries.filter { $0.provider == harness }
        let points = harnessEntries.compactMap { entry -> CGPoint? in
            let rawValue: Double?
            switch metric {
            case .allowance: rawValue = entry.usedPercent.map(Double.init)
            case .tokens: rawValue = entry.tokens.map(Double.init)
            }
            guard let rawValue else { return nil }
            let dayOffset = calendar.dateComponents(
                [.day],
                from: startDate,
                to: calendar.startOfDay(for: entry.date)
            ).day ?? 0
            guard dayOffset >= 0, dayOffset < range.rawValue else { return nil }
            let x = size.width * CGFloat(dayOffset) / CGFloat(max(1, range.rawValue - 1))
            let y = size.height - size.height * CGFloat(rawValue / maximum)
            return CGPoint(x: x, y: min(max(y, 0), size.height))
        }

        return Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func axisLabel(for fraction: Double) -> String {
        switch metric {
        case .allowance:
            return "\(Int(100 * fraction))%"
        case .tokens:
            return UsageFormatters.tokens(Int64(maximum * fraction))
        }
    }
}
