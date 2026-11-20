import Charts
import SwiftUI

enum DashboardDesign: String, CaseIterable, Identifiable {
    case nautical, ledger, cyber

    var id: String { rawValue }
    var title: String { self == .cyber ? "Night City" : rawValue.capitalized }
    var isTerminal: Bool { self == .cyber }
    var colorScheme: ColorScheme { .dark }

    func menuBarIcon(for provider: ProviderID) -> String {
        provider.glyph(for: self)
    }

    var background: Color {
        switch self {
        case .nautical: return Bridge.deep
        case .ledger: return Color(red: 0.090, green: 0.078, blue: 0.067)
        case .cyber: return Color(red: 0.035, green: 0.027, blue: 0.063)
        }
    }

    var ink: Color {
        switch self {
        case .nautical: return Bridge.cream
        case .ledger: return Color(red: 0.925, green: 0.894, blue: 0.835)
        case .cyber: return Color(red: 0.82, green: 0.97, blue: 1.0)
        }
    }

    var brand: Color {
        switch self {
        case .nautical: return Bridge.seafoam
        // The red pencil: the only colour on the page, kept for low allowance and today.
        case .ledger: return Color(red: 0.86, green: 0.42, blue: 0.38)
        case .cyber: return Color(red: 0.988, green: 0.933, blue: 0.039)
        }
    }
    var secondary: Color { self == .nautical ? Bridge.secondaryText : ink.opacity(0.70) }
    var selectionFill: Color {
        switch self {
        case .nautical: return Bridge.raised
        case .ledger: return ink
        case .cyber: return brand
        }
    }
    var selectionInk: Color { self == .nautical ? ink : background }
    var headingFont: Font.Design {
        switch self {
        case .nautical: return .default
        case .ledger: return .serif
        case .cyber: return .monospaced
        }
    }
    var bodyFont: Font.Design { isTerminal ? .monospaced : .default }
    /// Nautical reads figures like instrument dials, in mono.
    var numberFont: Font.Design { self == .nautical ? .monospaced : headingFont }
    var spacing: CGFloat { self == .ledger ? 16 : 12 }
    var cornerRadius: CGFloat { self == .nautical ? Bridge.plateRadius : 0 }
    var controlRadius: CGFloat { self == .nautical ? 8 : 0 }
    func textSize(_ size: CGFloat) -> CGFloat { self == .nautical ? max(11, size + 3) : max(10, size + 2) }
    var border: Color {
        switch self {
        case .nautical: return Bridge.hairline
        case .ledger: return ink.opacity(0.22)
        case .cyber: return brand.opacity(0.45)
        }
    }
    var warning: Color {
        switch self {
        case .nautical: return Bridge.coral
        case .ledger: return brand
        case .cyber: return Color(red: 1.0, green: 0.0, blue: 0.235)
        }
    }
    var surface: Color {
        switch self {
        case .nautical: return Bridge.well
        case .ledger: return .clear
        case .cyber: return Color(red: 0.075, green: 0.059, blue: 0.118)
        }
    }

    /// Labels are sentence case; Night City keeps its terminal caps.
    func label(_ text: String) -> String { isTerminal ? text.uppercased() : text }
    func tracking(_ caps: CGFloat) -> CGFloat { isTerminal ? caps : 0 }
    var labelWeight: Font.Weight { isTerminal ? .bold : .medium }

    /// Providers share one colour per theme, so chart lines tell them apart by stroke pattern.
    func lineDash(for provider: ProviderID) -> [CGFloat] {
        let patterns: [[CGFloat]] = [[], isTerminal ? [4, 3] : [5, 3], [1.5, 3], [8, 3, 2, 3], [2, 2]]
        let fixed: [ProviderID: Int] = [.codex: 0, .claude: 1, .grok: 2]
        let index = fixed[provider] ?? provider.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % patterns.count
        return patterns[index]
    }

    func accent(for provider: ProviderID) -> Color {
        switch self {
        case .nautical: return Bridge.tint(for: provider)
        case .ledger: return ink
        // Night City: yellow is the chrome, cyan is the data.
        case .cyber: return Color(red: 0.008, green: 0.843, blue: 0.949)
        }
    }

    func accent(for item: BridgeInstrument) -> Color {
        if item.isWarning { return warning }
        return accent(for: item.provider)
    }
}

struct DashboardVariantView: View {
    let design: DashboardDesign
    let items: [BridgeInstrument]
    var activity: (title: String, activity: TokenActivity)?
    let isLoading: Bool
    let lastUpdated: Date?
    var refreshMinutes = 5

    init(design: DashboardDesign, items: [BridgeInstrument], activity: (title: String, activity: TokenActivity)?, isLoading: Bool, lastUpdated: Date?, refreshMinutes: Int = 5) {
        self.design = design
        self.items = items
        self.activity = activity
        self.isLoading = isLoading
        self.lastUpdated = lastUpdated
        self.refreshMinutes = refreshMinutes
    }

    /// Codex's parsed snapshot as the token card, as the view was first written.
    init(design: DashboardDesign, items: [BridgeInstrument], snapshot: UsageSnapshot?, isLoading: Bool, lastUpdated: Date?) {
        self.init(design: design, items: items, activity: snapshot.map { ("Codex", $0.activity) }, isLoading: isLoading, lastUpdated: lastUpdated)
    }

    private var compact: Bool { PanelLayout.isCompact(items.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: design.spacing) {
            switch design {
            case .ledger, .nautical: ledger
            case .cyber: terminal
            }

            if let activity {
                tokenSummary(activity.title, activity.activity)
                activityChart(activity.title, activity.activity)
            }

            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "clock")
                }
                Text(isLoading ? "Refreshing usage…" : lastUpdated.map {
                    "Updated \($0.formatted(date: .omitted, time: .shortened))"
                } ?? "Waiting for usage")
                Spacer()
                Text(design.isTerminal ? "AUTO / \(refreshMinutes) MIN" : "Every \(refreshMinutes) min")
            }
            .font(.system(size: 10, design: design.isTerminal ? .monospaced : .default))
            .foregroundStyle(design.secondary)
        }
        .foregroundStyle(design.ink)
        .padding(.horizontal, Bridge.inset)
    }

    private func sectionTitle(_ title: String?) -> some View {
        Group {
            if let title {
                caption(title)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 0) {
            DesignHeading(design: design, eyebrow: "Dogwatch", title: "The daily ledger")
                .padding(.bottom, 12)
            HStack {
                caption("Account")
                Spacer()
                caption("Allowance left")
            }
            .padding(.bottom, 4)

            PanelScroll(count: items.count) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(PanelLayout.sections(items).enumerated()), id: \.offset) { _, section in
                        sectionTitle(section.title)
                        ForEach(section.items) { item in ledgerRow(item) }
                    }
                }
            }
        }
    }

    private func ledgerRow(_ item: BridgeInstrument) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.system(size: compact ? 16 : 22, design: .serif))
                    .lineLimit(1)
                Text(item.secondaryLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(design.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                reading(item, size: compact ? 20 : 34, font: .serif)
            }
            if item.remaining != nil {
                meter(item.remaining, accent: design.accent(for: item), height: 2)
            }
            if !compact { meters(item) }
            detail(item)
            if !compact { notes(item) }
        }
        .padding(.vertical, compact ? 8 : 12)
        .overlay(alignment: .bottom) {
            // The totals' double rule closes the last row instead.
            if item.id != items.last?.id || activity == nil {
                design.border.frame(height: 1)
            }
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 12) {
            DesignHeading(design: design, eyebrow: "Dogwatch // netrunner feed", title: "NIGHT CITY //")
            HStack {
                caption("Channel")
                Spacer()
                Text("REMAINING / %")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(design.background)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(design.brand)
            }
            PanelScroll(count: items.count) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(PanelLayout.sections(items).enumerated()), id: \.offset) { _, section in
                        if let title = section.title {
                            sectionTitle(title).padding(.horizontal, 12)
                        }
                        ForEach(section.items) { item in terminalRow(item) }
                    }
                }
                .background(design.surface)
                .overlay(Rectangle().strokeBorder(design.border))
            }
        }
    }

    private func terminalRow(_ item: BridgeInstrument) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: item.remaining == nil && item.amount == nil ? "circle.dashed" : item.isWarning ? "exclamationmark.triangle.fill" : "square.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(design.accent(for: item))
                Text(item.provider.logbookName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                reading(item, size: compact ? 18 : 30, font: .monospaced)
            }
            if item.amount == nil {
                meter(item.remaining, accent: design.accent(for: item), height: compact ? 4 : 8, glows: true)
                    .overlay {
                        HStack(spacing: 0) {
                            ForEach(0..<32, id: \.self) { _ in
                                Spacer(minLength: 0)
                                design.surface.frame(width: 2)
                            }
                        }
                        .accessibilityHidden(true)
                    }
            }
            if !compact { meters(item) }
            detail(item)
            if !compact {
                notes(item)
                Text(item.secondaryLabel.uppercased())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(design.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, compact ? 6 : 8)
        .overlay(alignment: .bottom) { design.border.frame(height: 1) }
    }

    /// Ledger marks today with its red pencil; Night City draws data in cyan, keeping yellow for chrome.
    private var dataColor: Color { design.isTerminal ? design.accent(for: .codex) : design.brand }

    private func caption(_ text: String) -> some View {
        Text(design.label(text))
            .font(.system(size: design == .ledger ? 11 : 9, weight: .medium, design: design == .ledger ? .default : .monospaced))
            .tracking(design.tracking(0.8))
            .foregroundStyle(design.secondary)
    }

    @ViewBuilder
    private func reading(_ item: BridgeInstrument, size: CGFloat, font: Font.Design) -> some View {
        if design == .ledger, item.remaining == nil, item.amount == nil {
            Text("No reading")
                .font(.system(size: 13))
                .foregroundStyle(design.secondary)
        } else {
            figure(item, size: size, font: font)
        }
    }

    private func figure(_ item: BridgeInstrument, size: CGFloat, font: Font.Design) -> some View {
        Text(PanelText.value(item))
            .font(.system(size: size, weight: design == .ledger ? .regular : .semibold, design: font))
            .monospacedDigit()
            .foregroundStyle(design.accent(for: item))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(item.amount.map { "\($0) \(item.amountCaption)" } ?? item.remaining.map { "\($0) percent remaining" } ?? "Usage unavailable")
    }

    private func meter(_ remaining: Int?, accent: Color, height: CGFloat, glows: Bool = false) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                design.ink.opacity(0.10)
                accent
                    .frame(width: geometry.size.width * CGFloat(remaining ?? 0) / 100)
                    // Only the live reading glows in Night City.
                    .shadow(color: accent.opacity(glows ? 0.8 : 0), radius: 4)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func meters(_ item: BridgeInstrument) -> some View {
        ForEach(item.meters) { gauge in
            HStack(spacing: 8) {
                caption(gauge.label)
                meter(gauge.remaining, accent: gauge.remaining <= item.warningThreshold ? design.warning : design.accent(for: item.provider).opacity(0.55), height: design == .ledger ? 2 : 3)
                Text("\(gauge.remaining)%")
                    .font(.system(size: design == .ledger ? 11 : 10, weight: design == .ledger ? .medium : .semibold, design: design.bodyFont))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(gauge.label), \(gauge.remaining) percent remaining")
        }
    }

    private func notes(_ item: BridgeInstrument) -> some View {
        ForEach(item.notes, id: \.self) { note in
            Text(note)
                .font(.system(size: design == .ledger ? 11 : 10, design: design.bodyFont))
                .foregroundStyle(design.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ item: BridgeInstrument) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.remaining == nil ? item.detail : item.isWarning ? "Low allowance · \(item.detail)" : item.detail)
                .lineLimit(compact ? 1 : nil)
            Spacer(minLength: 0)
            if item.remaining != nil || item.resetDate != nil {
                Text(UsageFormatters.resetCompact(item.resetDate))
                    .multilineTextAlignment(.trailing)
                    .help(UsageFormatters.reset(item.resetDate))
            }
        }
        .font(.system(size: design == .ledger ? 11 : 10, design: design.isTerminal ? .monospaced : .default))
        .foregroundStyle(item.isWarning ? design.accent(for: item) : design.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tokenSummary(_ title: String, _ snapshot: TokenActivity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if design == .ledger {
                DoubleRule(color: design.ink.opacity(0.4))
                    .padding(.bottom, 2)
            }
            caption(design == .ledger ? "\(title) tokens" : "\(title) / exact totals")
            HStack(alignment: .top, spacing: 0) {
                metric("Today", value: UsageFormatters.tokens(snapshot.tokensToday))
                metric("All time", value: UsageFormatters.tokens(snapshot.lifetimeTokens))
                metric("Credits", value: UsageFormatters.credits(snapshot.credits))
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(design.label(title))
                .font(.system(size: design == .ledger ? 11 : 8, weight: design == .ledger ? .regular : .semibold, design: design.bodyFont))
                .tracking(design.tracking(0.8))
                .foregroundStyle(design.secondary)
            Text(value)
                .font(.system(size: design == .ledger ? 24 : 20, weight: design == .ledger ? .regular : .semibold, design: design.numberFont))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(design.isTerminal && title == "Today" ? dataColor : design.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(design == .ledger ? 0 : 10)
        .padding(.vertical, design == .ledger ? 3 : 0)
        .background(design.surface, in: RoundedRectangle(cornerRadius: design.cornerRadius))
        .overlay(alignment: .leading) {
            if design.isTerminal { design.border.frame(width: 1) }
        }
    }

    private func activityChart(_ title: String, _ snapshot: TokenActivity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                caption(design == .ledger ? "This week" : "\(title) / daily tokens")
                Spacer()
                caption("7 days")
            }
            Chart(snapshot.lastSevenDays) { day in
                if design == .ledger {
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens), width: .ratio(0.35))
                        .foregroundStyle(Calendar.current.isDateInToday(day.date) ? design.brand : design.ink.opacity(0.22))
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(day.tokens.formatted()) tokens")
                } else {
                    AreaMark(x: .value("Day", day.date), y: .value("Tokens", day.tokens))
                        .interpolationMethod(design.isTerminal ? .stepEnd : .monotone)
                        .foregroundStyle(dataColor.opacity(0.12))
                        .accessibilityHidden(true)
                    LineMark(x: .value("Day", day.date), y: .value("Tokens", day.tokens))
                        .interpolationMethod(design.isTerminal ? .stepEnd : .monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(dataColor)
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(day.tokens.formatted()) tokens")
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(range: .plotDimension(padding: 8))
            .chartYAxis(.hidden)
            .frame(height: 42)
            HStack {
                ForEach(snapshot.lastSevenDays) { day in
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: design == .ledger ? 11 : 9, design: design.bodyFont))
                        .foregroundStyle(Calendar.current.isDateInToday(day.date) ? dataColor : design.secondary)
                        .frame(maxWidth: .infinity)
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.tokens.formatted()) tokens")
                }
            }
        }
    }
}
