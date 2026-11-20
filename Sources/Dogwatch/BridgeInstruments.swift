import Foundation

/// A second limit shown under the gauge, such as Claude's week under its five-hour session.
struct BridgeMeter: Equatable, Identifiable {
    let id: String
    let label: String
    let remaining: Int
}

/// Everything a dashboard design draws for one provider, built from its snapshot and settings.
/// Views draw instruments only; they never look inside a snapshot.
struct BridgeInstrument: Equatable, Identifiable {
    enum State: Equatable {
        /// Has a reading, or is waiting for its first one.
        case ready
        case loading
        case failed
        /// Switched on but missing something only the user can provide: a key, a sign-in.
        case notSetUp
    }

    let provider: ProviderID
    /// Percentage left of the primary reading, when it has one.
    let remaining: Int?
    let detail: String
    let resetDate: Date?
    let secondaryLabel: String
    var meters: [BridgeMeter] = []
    /// The primary reading as an amount, when it has no percentage: "$12.40", "1.5k credits".
    var amount: String? = nil
    /// What the amount is: "left" for a balance, "spent" for spend.
    var amountCaption = "left"
    /// Extra lines: other balances and spend, freshness, where the numbers came from.
    var notes: [String] = []
    var state: State = .ready
    var warningThreshold: Int = 20
    /// Show the percentage used instead of left.
    var showsUsed: Bool = false
    var category: ProviderCategory = .subscription
    /// The menu bar's text for this provider: "76%", "$12.40", "—".
    var menuValue: String = "—"
    /// The percentage the menu bar's value is based on, to pick the lowest.
    var menuPercent: Int? = nil

    init(
        provider: ProviderID,
        remaining: Int?,
        detail: String,
        resetDate: Date?,
        secondaryLabel: String,
        weeklyRemaining: Int? = nil
    ) {
        self.provider = provider
        self.remaining = remaining
        self.detail = detail
        self.resetDate = resetDate
        self.secondaryLabel = secondaryLabel
        self.meters = weeklyRemaining.map { [BridgeMeter(id: "weekly", label: "Week", remaining: $0)] } ?? []
        self.menuValue = remaining.map { "\($0)%" } ?? "—"
        self.menuPercent = remaining
    }

    var id: String { provider.rawValue }
    var title: String { provider.title }

    /// The first second meter, usually the week.
    var weeklyRemaining: Int? { meters.first?.remaining }

    var isWarning: Bool {
        guard let remaining else { return false }
        return remaining <= warningThreshold
    }

    /// The figure to draw: percentage left, or used when the user chose that.
    var displayPercent: Int? {
        guard let remaining else { return nil }
        return showsUsed ? 100 - remaining : remaining
    }

    var percentCaption: String { showsUsed ? "used" : "left" }
}

/// How the user wants one provider shown, from `config.json`.
struct InstrumentOptions: Equatable {
    var primary: String? = nil
    var showsUsed = false
    var label: String? = nil
    var warningThreshold = 20
    var userLimits: [String: Double] = [:]
    var amountStyle: AmountStyle = .compact
}

enum BridgeLayout {
    /// The instrument for one provider: its primary reading on the gauge, other windows as
    /// meters, balances and spend as notes, and the menu bar's value.
    static func instrument(
        descriptor: ProviderDescriptor,
        snapshot rawSnapshot: ProviderSnapshot?,
        error: String?,
        isLoading: Bool = false,
        needsSetUp: Bool = false,
        options: InstrumentOptions = InstrumentOptions()
    ) -> BridgeInstrument {
        let idleLabel = descriptor.idleLabel ?? descriptor.name
        guard let snapshot = rawSnapshot?.applying(userLimits: options.userLimits) else {
            var item = BridgeInstrument(
                provider: descriptor.id,
                remaining: nil,
                detail: error ?? (isLoading ? "Reading…" : "Waiting for usage"),
                resetDate: nil,
                secondaryLabel: idleLabel
            )
            item.state = needsSetUp ? .notSetUp : error != nil ? .failed : isLoading ? .loading : .ready
            item.menuValue = isLoading ? "…" : "—"
            item.category = descriptor.category
            item.warningThreshold = options.warningThreshold
            item.showsUsed = options.showsUsed
            return item
        }

        guard let primary = snapshot.primary(override: options.primary) else {
            var item = BridgeInstrument(
                provider: descriptor.id,
                remaining: nil,
                detail: error ?? snapshot.note ?? "No usage window reported",
                resetDate: nil,
                secondaryLabel: options.label ?? snapshot.label ?? snapshot.plan ?? idleLabel
            )
            item.category = descriptor.category
            item.state = error != nil ? .failed : .ready
            return item
        }

        var item = BridgeInstrument(
            provider: descriptor.id,
            remaining: primary.remainingPercent,
            detail: primary.detailText,
            resetDate: primary.resetsAt,
            secondaryLabel: options.label ?? snapshot.label ?? snapshot.plan ?? primary.name
        )
        item.category = descriptor.category
        item.warningThreshold = options.warningThreshold
        item.showsUsed = options.showsUsed
        if primary.remainingPercent == nil, let amount = primary.amount {
            item.amount = UsageFormatters.amount(amount, style: options.amountStyle)
            item.amountCaption = primary.spend != nil ? "spent" : primary.window != nil ? "used" : "left"
        }

        for reading in snapshot.secondary(override: options.primary) {
            if reading.window != nil, let remaining = reading.remainingPercent {
                item.meters.append(BridgeMeter(id: reading.id, label: reading.meterLabel ?? reading.name, remaining: remaining))
            } else if let remaining = reading.remainingPercent {
                item.notes.append("\(reading.name) \(remaining)% left")
            } else if let amount = reading.amount {
                let verb = reading.spend != nil ? "spent" : reading.window != nil ? "used" : "left"
                item.notes.append("\(reading.name) \(UsageFormatters.amount(amount, style: options.amountStyle)) \(verb)")
            }
        }
        if let freshness = primary.freshness { item.notes.append(freshness) }
        if let note = snapshot.note { item.notes.append(note) }

        // The menu bar shows the primary, or the tightest window for providers whose real limit
        // can be a different one (Claude), so it never overstates what is left.
        let percent = snapshot.menuBar == .tightest && options.primary == nil
            ? snapshot.tightestRemainingPercent ?? primary.remainingPercent
            : primary.remainingPercent
        item.menuPercent = percent
        if let percent {
            item.menuValue = "\(options.showsUsed ? 100 - percent : percent)%"
        } else if let amount = primary.amount {
            item.menuValue = UsageFormatters.menuAmount(amount)
        }
        return item
    }

    /// Claude's instrument from its parsed snapshot. Kept for tests that check Claude's windows.
    static func claudeInstrument(_ claude: ClaudeUsageSnapshot?, error: String?) -> BridgeInstrument {
        instrument(descriptor: ClaudeProvider().descriptor, snapshot: claude.map(ClaudeProvider.snapshot), error: error)
    }

    /// The provider that needs attention first: the lowest percentage left, providers with a
    /// reading before those without, then the given order.
    static func hero(in items: [BridgeInstrument]) -> BridgeInstrument? {
        items.enumerated().min { isMoreUrgent($0, $1) }?.element
    }

    static func satellites(in items: [BridgeInstrument]) -> [BridgeInstrument] {
        guard let hero = hero(in: items) else { return [] }
        return items.filter { $0.provider != hero.provider }
    }

    private static func isMoreUrgent(_ lhs: (offset: Int, element: BridgeInstrument), _ rhs: (offset: Int, element: BridgeInstrument)) -> Bool {
        switch (lhs.element.remaining, rhs.element.remaining) {
        case let (left?, right?):
            return left != right ? left < right : lhs.offset < rhs.offset
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.offset < rhs.offset
        }
    }
}
