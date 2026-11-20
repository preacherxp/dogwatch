import AppKit
import Foundation
import ServiceManagement

/// One provider's latest result.
struct ProviderState: Equatable {
    var snapshot: ProviderSnapshot?
    var error: ProviderError?
    var isLoading = false
    var lastAttempt: Date?
    var lastSuccess: Date?
    /// Set when the provider can't run here: not installed, no key.
    var unavailableReason: String?
    /// After a rate limit, the provider isn't asked again before this.
    var notBefore: Date?
}

/// Owns configuration, providers and their results. Each switched-on provider fetches on its own
/// schedule, concurrently, with a timeout; a slow or failing provider never delays or blanks
/// another, and nothing runs for a provider that is switched off.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var config: DogwatchConfig
    @Published private(set) var configMessage: String?
    @Published private(set) var states: [ProviderID: ProviderState] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var hasPlayedIntro = false
    @Published private(set) var historyEntries: [UsageHistoryEntry] = []
    @Published private(set) var historyRange: UsageHistoryRange = .sevenDays
    @Published private(set) var historyErrorMessage: String?

    let configStore: ConfigStore
    let secrets: SecretStore
    private let builtIn: [any UsageProvider]
    private(set) var providers: [ProviderID: any UsageProvider] = [:]
    private let historyDatabase: UsageHistoryDatabase?
    private let transport: HTTPTransport
    private let tools: LocalTools
    private let now: () -> Date
    private var tasks: [ProviderID: Task<Void, Never>] = [:]
    private var timer: Timer?

    init(
        configStore: ConfigStore,
        providers: [any UsageProvider] = ProviderRegistry.builtIn,
        historyDatabase: UsageHistoryDatabase?,
        historyError: String? = nil,
        secrets: SecretStore = KeychainSecretStore(),
        transport: HTTPTransport = HTTPClient.hardenedSession,
        tools: LocalTools = LocalTools(),
        now: @escaping () -> Date = Date.init,
        automaticallyRefresh: Bool = true
    ) {
        self.configStore = configStore
        self.config = configStore.config
        self.configMessage = configStore.message
        self.builtIn = providers
        self.historyDatabase = historyDatabase
        self.historyErrorMessage = historyError
        self.secrets = secrets
        self.transport = transport
        self.tools = tools
        self.now = now
        rebuildProviders()
        loadHistory()
        guard automaticallyRefresh else { return }
        refresh()
        // A short tick: each provider is fetched when its own interval has passed, and the
        // configuration file is re-read when it changes.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadConfigIfChanged()
                self?.refreshDue()
            }
        }
    }

    /// The store tests and previews use: settings in memory, migrated from `defaults` the way
    /// the app migrates its old preferences; the three original providers only.
    convenience init(defaults: UserDefaults = .standard, historyDatabase: UsageHistoryDatabase? = nil, automaticallyRefresh: Bool = true) {
        self.init(
            configStore: .inMemory(ConfigStore.migratedConfig(from: defaults)),
            providers: [ClaudeProvider(), CodexProvider(), GrokProvider()],
            historyDatabase: historyDatabase,
            secrets: InMemorySecretStore(),
            automaticallyRefresh: automaticallyRefresh
        )
    }

    /// The app's store: `config.json` in Application Support, the Keychain, the real network.
    static func live() -> UsageStore {
        var historyError: String?
        let database: UsageHistoryDatabase?
        do {
            database = try UsageHistoryDatabase()
        } catch {
            database = nil
            historyError = error.localizedDescription
        }
        return UsageStore(configStore: .live(), historyDatabase: database, historyError: historyError)
    }

    // MARK: Providers

    /// Built-in providers plus the user's custom ones from the configuration.
    private func rebuildProviders() {
        var all: [ProviderID: any UsageProvider] = [:]
        for provider in builtIn { all[provider.id] = provider }
        var problems: [String] = []
        for (index, entry) in config.customProviders.enumerated() {
            do {
                let spec = try CustomProviderSpec(json: entry)
                if all[spec.id] != nil {
                    problems.append("customProviders[\(index)]: \(spec.id) is already a provider id.")
                    continue
                }
                all[spec.id] = DeclarativeProvider(spec: spec)
            } catch {
                problems.append("customProviders[\(index)]: \(error.localizedDescription)")
            }
        }
        providers = all
        ProviderDirectory.shared.register(all.values.map(\.descriptor))
        let messages = [configStore.message, problems.isEmpty ? nil : problems.joined(separator: " ")].compactMap { $0 }
        configMessage = messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    /// Every known provider: switched-on ones in configured order, then the rest by name.
    var allProviderIDs: [ProviderID] {
        let ordered = config.providers.map(\.id).filter { providers[$0] != nil }
        let rest = providers.keys.filter { !ordered.contains($0) }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return ordered + rest
    }

    /// Switched-on providers, in the configured order.
    var enabledProviders: [ProviderID] {
        config.enabledProviders.filter { providers[$0] != nil }
    }

    func descriptor(_ id: ProviderID) -> ProviderDescriptor? {
        providers[id]?.descriptor
    }

    func isVisible(_ id: ProviderID) -> Bool {
        enabledProviders.contains(id)
    }

    /// The legacy view of which of the three original providers are on.
    var visibility: HarnessVisibility {
        HarnessVisibility(visible: Set(enabledProviders))
    }

    func canHide(_ id: ProviderID) -> Bool {
        isVisible(id) && enabledProviders.count > 1
    }

    /// Switches a provider on or off. At least one stays on.
    func setHarness(_ id: ProviderID, visible: Bool) {
        if !visible, !canHide(id) { return }
        if visible == isVisible(id) { return }
        updateConfig { $0.update(id) { $0.enabled = visible } }
        if visible {
            fetch(id, userInitiated: true)
        } else {
            tasks[id]?.cancel()
            tasks[id] = nil
            states[id]?.isLoading = false
        }
    }

    /// Reorders a subset of providers (one group in settings) among themselves; everything else
    /// keeps its place.
    func moveProviders(_ subset: [ProviderID], from source: IndexSet, to destination: Int) {
        var moved = subset
        moved.move(fromOffsets: source, toOffset: destination)
        updateConfig { config in
            var ids = allProviderIDs
            let slots = ids.indices.filter { subset.contains(ids[$0]) }
            for (slot, id) in zip(slots, moved) { ids[slot] = id }
            config.providers = ids.map { id in config.provider(id) ?? ProviderConfig(id: id, enabled: false) }
        }
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        updateConfig { config in
            var ids = allProviderIDs
            ids.move(fromOffsets: source, toOffset: destination)
            config.providers = ids.map { id in config.provider(id) ?? ProviderConfig(id: id, enabled: false) }
        }
    }

    // MARK: Configuration

    func updateConfig(_ change: (inout DogwatchConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        let customChanged = next.customProviders != config.customProviders
        config = next
        do {
            try configStore.save(next)
        } catch {
            configMessage = "Settings could not be saved: \(error.localizedDescription)"
        }
        if customChanged { rebuildProviders() }
    }

    private func reloadConfigIfChanged() {
        guard configStore.reloadIfChanged() else { return }
        let previouslyEnabled = Set(enabledProviders)
        config = configStore.config
        rebuildProviders()
        for id in previouslyEnabled.subtracting(enabledProviders) { tasks[id]?.cancel(); tasks[id] = nil }
        for id in Set(enabledProviders).subtracting(previouslyEnabled) { fetch(id, userInitiated: false) }
    }

    func options(for id: ProviderID) -> InstrumentOptions {
        let provider = config.provider(id)
        return InstrumentOptions(
            primary: provider?.primary,
            showsUsed: (provider?.percentage ?? config.percentage) == .used,
            label: provider?.label,
            warningThreshold: provider?.warnAt ?? 20,
            userLimits: provider?.limits ?? [:],
            amountStyle: config.amounts
        )
    }

    /// The interval between fetches for a provider: its own setting, else the global one, never
    /// below the provider's minimum.
    func refreshInterval(for id: ProviderID) -> TimeInterval {
        let configured = config.provider(id)?.refreshInterval ?? config.refreshInterval
        return max(configured, descriptor(id)?.minimumRefreshInterval ?? 60)
    }

    // MARK: Settings actions

    func availability(of id: ProviderID) -> ProviderAvailability? {
        guard let provider = providers[id], let context = context(for: id) else { return nil }
        return provider.availability(in: context)
    }

    /// Fetches once and describes the result, for the settings "Test connection" button. A
    /// success also updates the panel.
    func testConnection(_ id: ProviderID) async -> (ok: Bool, message: String) {
        guard let provider = providers[id], let context = context(for: id) else { return (false, "Unknown provider.") }
        let availability = provider.availability(in: context)
        guard availability.isAvailable else { return (false, availability.reason ?? "Not available.") }
        do {
            let snapshot = try await withTimeout(provider.descriptor.timeout) { try await provider.fetch(in: context) }
            var state = states[id] ?? ProviderState()
            state.snapshot = snapshot
            state.error = nil
            state.lastAttempt = now()
            state.lastSuccess = now()
            states[id] = state
            let readings = snapshot.readings.map(\.name).joined(separator: ", ")
            return (true, readings.isEmpty ? "Connected. \(snapshot.note ?? "No readings.")" : "Connected: \(readings).")
        } catch let error as ProviderError {
            return (false, "\(error.localizedDescription) (\(error.kind))")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Starts Dogwatch at login with `SMAppService`. macOS may ask the user to approve it in
    /// System Settings > General > Login Items; the message says so.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            updateConfig { $0.launchAtLogin = enabled }
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                configMessage = "Approve Dogwatch in System Settings > General > Login Items to start it at login."
            }
        } catch {
            configMessage = "Launch at login could not be changed: \(error.localizedDescription)"
        }
    }

    var launchAtLoginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "On"
        case .requiresApproval: return "Waiting for approval in System Settings"
        case .notFound: return "Only available when Dogwatch runs as an app"
        default: return "Off"
        }
    }

    /// Adds a custom provider definition, after validating it.
    func addCustomProvider(_ json: JSONValue) throws {
        let spec = try CustomProviderSpec(json: json)
        guard providers[spec.id] == nil else { throw CustomProviderError.invalid("\(spec.id) is already a provider id.") }
        updateConfig { config in
            config.customProviders.append(json)
            config.providers.append(ProviderConfig(id: spec.id))
        }
    }

    func removeCustomProvider(_ id: ProviderID) {
        updateConfig { config in
            config.customProviders.removeAll { $0["id"]?.stringValue == id.rawValue }
            config.providers.removeAll { $0.id == id }
        }
        try? secrets.delete(id)
        states[id] = nil
    }

    func isCustom(_ id: ProviderID) -> Bool {
        config.customProviders.contains { $0["id"]?.stringValue == id.rawValue }
    }

    // MARK: Secrets

    func hasKey(_ id: ProviderID) -> Bool {
        secrets.read(id)?.isEmpty == false
    }

    func saveKey(_ key: String, for id: ProviderID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try secrets.delete(id) } else { try secrets.write(trimmed, for: id) }
        states[id] = nil
        if isVisible(id) { fetch(id, userInitiated: true) }
    }

    func removeKey(for id: ProviderID) throws {
        try secrets.delete(id)
        states[id] = nil
    }

    // MARK: Fetching

    func context(for id: ProviderID) -> ProviderContext? {
        guard let descriptor = descriptor(id) else { return nil }
        let providerConfig = config.provider(id)
        var hosts = descriptor.allowedHosts
        var baseURL = providerConfig?.baseURL.flatMap(URL.init(string:))
        if let url = baseURL, let host = url.host?.lowercased() {
            let offered = descriptor.baseURLs.contains { $0.url.host?.lowercased() == host }
            if descriptor.acceptsCustomBaseURL || offered { hosts.append(host) } else { baseURL = nil }
        }
        var tools = self.tools
        if tools.gate is DeclaredCommandGate { tools.gate = DeclaredCommandGate(declared: descriptor.commands) }
        let secrets = self.secrets
        return ProviderContext(
            http: HTTPClient(allowedHosts: hosts, transport: transport),
            key: { secrets.read(id) },
            settings: ProviderSettings(baseURL: baseURL, values: providerConfig?.settings ?? [:]),
            local: tools,
            now: now
        )
    }

    /// Fetches every switched-on provider that hasn't been read within its minimum interval.
    /// Called when the panel opens, and by the refresh button with `userInitiated: true`, which
    /// also retries providers waiting for the user (a denied Keychain prompt).
    func refresh(userInitiated: Bool = false) {
        for id in enabledProviders {
            let state = states[id]
            if !userInitiated, state?.error?.waitsForUser == true { continue }
            if let notBefore = state?.notBefore, notBefore > now() { continue }
            if let last = state?.lastAttempt, now().timeIntervalSince(last) < (descriptor(id)?.minimumRefreshInterval ?? 60) { continue }
            fetch(id, userInitiated: userInitiated)
        }
    }

    /// Fetches providers whose own interval has passed.
    func refreshDue() {
        for id in enabledProviders {
            let state = states[id]
            if state?.error?.waitsForUser == true { continue }
            if let notBefore = state?.notBefore, notBefore > now() { continue }
            if let last = state?.lastAttempt, now().timeIntervalSince(last) < refreshInterval(for: id) { continue }
            fetch(id, userInitiated: false)
        }
    }

    func fetch(_ id: ProviderID, userInitiated: Bool) {
        guard tasks[id] == nil, let provider = providers[id], let context = context(for: id) else { return }
        let availability = provider.availability(in: context)
        var state = states[id] ?? ProviderState()
        state.lastAttempt = now()
        guard availability.isAvailable else {
            state.unavailableReason = availability.reason
            state.isLoading = false
            states[id] = state
            return
        }
        state.unavailableReason = nil
        state.isLoading = true
        states[id] = state

        let timeout = provider.descriptor.timeout
        tasks[id] = Task { [weak self] in
            let result: Result<ProviderSnapshot, ProviderError>
            do {
                result = .success(try await withTimeout(timeout) { try await provider.fetch(in: context) })
            } catch let error as ProviderError {
                result = .failure(error)
            } catch is CancellationError {
                await MainActor.run { self?.finishCancelled(id) }
                return
            } catch {
                result = .failure(.unexpectedResponse(error.localizedDescription))
            }
            await MainActor.run { self?.finish(id, result) }
        }
    }

    private func finishCancelled(_ id: ProviderID) {
        tasks[id] = nil
        states[id]?.isLoading = false
    }

    private func finish(_ id: ProviderID, _ result: Result<ProviderSnapshot, ProviderError>) {
        tasks[id] = nil
        guard isVisible(id) else { states[id]?.isLoading = false; return }
        var state = states[id] ?? ProviderState()
        state.isLoading = false
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.error = nil
            state.notBefore = nil
            state.lastSuccess = now()
            recordHistory(id, snapshot)
        case .failure(let error):
            state.error = error
            if case .rateLimited(let retryAfter) = error {
                state.notBefore = now().addingTimeInterval(max(retryAfter ?? 300, descriptor(id)?.minimumRefreshInterval ?? 60))
            }
        }
        states[id] = state
        if !isLoading { lastUpdated = now() }
    }

    // MARK: What views read

    var isLoading: Bool {
        enabledProviders.contains { states[$0]?.isLoading == true }
    }

    func instrument(for id: ProviderID) -> BridgeInstrument? {
        guard let descriptor = descriptor(id) else { return nil }
        let state = states[id]
        let needsKey = descriptor.credential.needsPastedKey && !hasKey(id)
            && state?.unavailableReason == nil
        let error = state?.error?.localizedDescription ?? state?.unavailableReason ?? (needsKey ? "No key set. Add one in settings." : nil)
        return BridgeLayout.instrument(
            descriptor: descriptor,
            snapshot: state?.snapshot,
            error: error,
            isLoading: state?.isLoading ?? false,
            needsSetUp: needsKey || state?.unavailableReason != nil,
            options: options(for: id)
        )
    }

    /// Instruments for every switched-on provider, in the configured order.
    var instruments: [BridgeInstrument] {
        enabledProviders.compactMap(instrument(for:))
    }

    /// The first switched-on provider that reports token activity (Codex), for the token card.
    var activity: (provider: ProviderID, activity: TokenActivity)? {
        for id in enabledProviders {
            if let activity = states[id]?.snapshot?.activity { return (id, activity) }
        }
        return nil
    }

    /// The menu bar's providers, following `menuBar` in the configuration.
    var menuBarEntries: [MenuBarEntry] {
        let candidates = enabledProviders
            .filter { config.provider($0)?.inMenuBar ?? true }
            .compactMap { id in instrument(for: id).map { (id, $0) } }
        var chosen = candidates
        if config.menuBarMode == .lowest, let lowest = candidates.min(by: { ($0.1.menuPercent ?? 101) < ($1.1.menuPercent ?? 101) }) {
            chosen = [lowest]
        }
        if let max = config.menuBarMaxItems { chosen = Array(chosen.prefix(max)) }
        if chosen.isEmpty, let first = candidates.first { chosen = [first] }
        return chosen.map { MenuBarEntry(provider: $0.0, value: $0.1.menuValue) }
    }

    var menuBarTitle: String {
        MenuBarLabel.accessibilityText(menuBarEntries)
    }

    func menuTitle(for id: ProviderID) -> String {
        instrument(for: id)?.menuValue ?? "—"
    }

    var hasAnyUsageData: Bool {
        enabledProviders.contains { states[$0]?.snapshot != nil }
    }

    var hasSignalError: Bool {
        enabledProviders.contains { states[$0]?.error != nil }
    }

    var statusText: String {
        if isLoading, !hasAnyUsageData { return "Reading the tide…" }
        if let configMessage { return configMessage }
        for id in enabledProviders {
            if let error = states[id]?.error { return "\(id.title): \(error.localizedDescription)" }
        }
        let names = enabledProviders.map(\.title).joined(separator: " + ")
        if let date = lastUpdated {
            return "\(names) updated \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "\(names) connected"
    }

    // MARK: History

    func setHistoryRange(_ range: UsageHistoryRange) {
        guard historyRange != range else { return }
        historyRange = range
        loadHistory()
    }

    func markIntroPlayed() {
        hasPlayedIntro = true
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func recordHistory(_ id: ProviderID, _ snapshot: ProviderSnapshot) {
        guard let historyDatabase else { return }
        do {
            try historyDatabase.record(provider: id, snapshot: snapshot, observedAt: now())
            historyErrorMessage = nil
            loadHistory()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    private func loadHistory() {
        guard let historyDatabase else { return }
        do {
            historyEntries = try historyDatabase.entries(in: historyRange, now: now())
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }
}
