import AppKit
import SwiftUI

/// Settings: the provider list (search, on/off, drag to reorder), general options,
/// and a detail page per provider. Every change is written to `config.json`.
struct HarnessSettingsView: View {
    @ObservedObject var store: UsageStore
    var design: DashboardDesign = .nautical
    @State private var search = ""
    @State private var selected: ProviderID?
    @State private var addingCustom = false
    @State private var showingGeneral = false

    var body: some View {
        if let selected {
            ProviderDetailView(store: store, id: selected, design: design) { self.selected = nil }
        } else if showingGeneral {
            VStack(alignment: .leading, spacing: design.spacing) {
                HStack(spacing: 8) {
                    Button { showingGeneral = false } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(BridgeIconButton(design: design))
                        .accessibilityLabel("Back to providers")
                    Text("General")
                        .font(.system(size: 17, weight: .medium, design: design.headingFont))
                        .foregroundStyle(design.ink)
                }
                GeneralSettings(store: store, design: design)
            }
        } else if addingCustom {
            CustomProviderForm(store: store, design: design) { addingCustom = false }
        } else {
            overview
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: design.spacing) {
            if design == .nautical {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Providers")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(design.ink)
                    Text("Show or stow a provider in the menu bar and logbook")
                        .font(.system(size: 12))
                        .foregroundStyle(design.secondary)
                }
            } else {
                DesignHeading(design: design, eyebrow: "Preferences / providers",
                    title: design == .ledger ? "A personal edition" : "CONFIG /",
                    subtitle: "Choose which providers appear in Dogwatch")
            }

            if store.allProviderIDs.count > 6 {
                TextField("Search providers", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: design.textSize(10)))
                    .accessibilityLabel("Search providers")
            }

            providerList

            Text(design == .nautical ? "Keep at least one provider on deck" : "Keep at least one provider visible")
                .font(.system(size: design.textSize(9), weight: .medium, design: design.bodyFont))
                .foregroundStyle(design.secondary)

            HStack(spacing: 12) {
                Button("General settings…") { showingGeneral = true }
                Button("Add a custom provider…") { addingCustom = true }
                Spacer()
            }
            .buttonStyle(.link)
            .font(.system(size: design.textSize(9)))

            signalPlate

            aboutLine
        }
    }

    private var filteredIDs: [ProviderID] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.allProviderIDs }
        return store.allProviderIDs.filter { id in
            id.title.lowercased().contains(query) || id.rawValue.contains(query) || id.summary.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var providerList: some View {
        if store.allProviderIDs.count <= 4 {
            // Few providers: plates, like the dashboard.
            VStack(spacing: Bridge.stack) {
                ForEach(filteredIDs) { id in harnessRow(id) }
            }
        } else {
            // Grouped by kind, each group in the configured order; drag to reorder within a group.
            List {
                ForEach(ProviderCategory.allCases, id: \.self) { category in
                    let ids = filteredIDs.filter { $0.category == category }
                    if !ids.isEmpty {
                        // A plain row, not a Section header: a plain list's headers float on an
                        // opaque bar that clashes with every design's backdrop.
                        Text(design.label(category.title))
                            .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                            .tracking(design.tracking(1.3))
                            .foregroundStyle(design.secondary)
                            .padding(.top, 6)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 0, trailing: 0))
                            .moveDisabled(true)
                            .listRowSeparator(.hidden)
                        ForEach(ids) { id in
                            harnessRow(id)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                                .listRowSeparator(.hidden)
                        }
                        .onMove { source, destination in
                            guard search.isEmpty else { return }
                            store.moveProviders(ids, from: source, to: destination)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(filteredIDs.count) * 62 + 48, 360))
        }
    }

    private var signalPlate: some View {
        VStack(alignment: .leading, spacing: Bridge.tight) {
            Text(design.label(design == .nautical ? "Signal" : "Connection"))
                .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                .tracking(design.tracking(1.3))
                .foregroundStyle(design.secondary)

            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(store.hasSignalError ? design.warning : design == .nautical ? Bridge.seafoam : design.accent(for: .codex))
                    .frame(width: 6, height: 6)
                Text(design != .nautical && store.isLoading ? "Refreshing usage…" : store.statusText)
                    .font(.system(size: design.textSize(10), weight: .medium, design: design.bodyFont))
                    .foregroundStyle(design.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button { store.refresh(userInitiated: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(store.isLoading ? .degrees(180) : .zero)
                }
                .buttonStyle(BridgeIconButton(design: design))
                .disabled(store.isLoading)
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")

                Button(action: store.quit) {
                    Image(systemName: "power")
                }
                .buttonStyle(BridgeIconButton(design: design))
                .help("Quit Dogwatch")
                .accessibilityLabel("Quit Dogwatch")
            }
        }
        .instrumentPlate(design: design)
    }

    // The bundle's icon and version. Under `swift run` or the tests Bundle.main is not
    // Dogwatch.app, so only the name shows.
    private var aboutLine: some View {
        let bundle = Bundle.main
        let isApp = bundle.bundleURL.pathExtension == "app"
            && bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Dogwatch"
        let version = isApp ? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String : nil
        return HStack(spacing: 8) {
            if isApp, let icon = NSApp?.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            Text(["Dogwatch", version].compactMap { $0 }.joined(separator: " "))
                .font(.system(size: design.textSize(10), weight: .medium, design: design.bodyFont))
                .foregroundStyle(design.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func harnessRow(_ id: ProviderID) -> some View {
        let isOn = store.isVisible(id)
        let canToggleOff = store.canHide(id)
        let accent = design.accent(for: id)

        return HStack(alignment: .center, spacing: 10) {
            switch design {
            case .nautical:
                Image(systemName: id.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(accent)
                    .frame(width: 20)
            case .cyber:
                Image(systemName: id.glyph(for: design))
                    .font(.system(size: design.textSize(14), weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent.opacity(0.2)))
            case .ledger:
                EmptyView()
            }

            Button { selected = id } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(design.label(id.title))
                            .font(.system(size: design == .ledger ? 20 : design.textSize(12), weight: design == .cyber ? .semibold : design == .ledger ? .regular : .medium, design: design.headingFont))
                            .tracking(design.tracking(1.1))
                            .foregroundStyle(design.ink)
                            .lineLimit(1)
                    }
                    Text(id.summary)
                        .font(.system(size: design.textSize(10), weight: design == .cyber ? .medium : .regular, design: design.bodyFont))
                        .foregroundStyle(design.secondary)
                        .lineLimit(2)
                    if design == .cyber {
                        stateBadge(isOn: isOn, accent: accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(id.title) settings")
            .accessibilityHint("Opens \(id.title) settings")

            Spacer(minLength: 8)

            Toggle(id.title, isOn: binding(for: id))
                .labelsHidden()
                .toggleStyle(DeckToggleStyle(accent: accent, design: design))
                .accessibilityLabel(id.title)
                .disabled(isOn && !canToggleOff)
                .help(isOn && !canToggleOff ? "Keep at least one provider visible" : "Show or hide \(id.title)")
                .accessibilityHint(isOn && !canToggleOff ? "At least one provider must stay visible" : "")
        }
        .instrumentPlate(design: design)
        .opacity(isOn || design != .nautical ? 1 : 0.72)
    }

    private func stateBadge(isOn: Bool, accent: Color) -> some View {
        Text(isOn ? "VISIBLE" : "HIDDEN")
            .font(.system(size: design.textSize(7), weight: .bold, design: design.bodyFont))
            .tracking(0.8)
            .foregroundStyle(isOn ? accent : design.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                Rectangle()
                    .stroke((isOn ? accent : design.secondary).opacity(0.4), lineWidth: 1)
            )
    }

    private func binding(for id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { store.isVisible(id) },
            set: { store.setHarness(id, visible: $0) }
        )
    }
}

/// Global options: theme, percentages, amounts, refresh, the menu bar, launch at login.
private struct GeneralSettings: View {
    @ObservedObject var store: UsageStore
    let design: DashboardDesign

    var body: some View {
        VStack(alignment: .leading, spacing: Bridge.stack) {
            label("Theme")
            DesignSegmentedPicker(design: design, options: DashboardDesign.allCases, title: \.title, selection: Binding(
                get: { store.config.theme }, set: { value in store.updateConfig { $0.theme = value } }))

            HStack(spacing: Bridge.stack) {
                VStack(alignment: .leading, spacing: Bridge.tight) {
                    label("Show percentage")
                    Picker("Show percentage", selection: Binding(get: { store.config.percentage }, set: { value in store.updateConfig { $0.percentage = value } })) {
                        Text("Left").tag(PercentageMode.left)
                        Text("Used").tag(PercentageMode.used)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: Bridge.tight) {
                    label("Amounts")
                    Picker("Amounts", selection: Binding(get: { store.config.amounts }, set: { value in store.updateConfig { $0.amounts = value } })) {
                        Text("$1.2k").tag(AmountStyle.compact)
                        Text("$1,200.00").tag(AmountStyle.full)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
            }

            HStack(spacing: Bridge.stack) {
                VStack(alignment: .leading, spacing: Bridge.tight) {
                    label("Menu bar")
                    Picker("Menu bar", selection: Binding(get: { store.config.menuBarMode }, set: { value in store.updateConfig { $0.menuBarMode = value } })) {
                        Text("All").tag(MenuBarMode.all)
                        Text("Lowest").tag(MenuBarMode.lowest)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                Stepper(value: Binding(get: { store.config.menuBarMaxItems ?? 0 }, set: { value in store.updateConfig { $0.menuBarMaxItems = value == 0 ? nil : value } }), in: 0...12) {
                    Text(store.config.menuBarMaxItems.map { "At most \($0)" } ?? "No limit")
                        .font(.system(size: design.textSize(9), design: design.bodyFont))
                        .foregroundStyle(design.ink)
                }
            }

            Stepper(value: Binding(get: { Int(store.config.refreshInterval / 60) }, set: { value in store.updateConfig { $0.refreshInterval = TimeInterval(value) * 60 } }), in: 1...120) {
                Text("Refresh every \(Int(store.config.refreshInterval / 60)) min")
                    .font(.system(size: design.textSize(9), design: design.bodyFont))
                    .foregroundStyle(design.ink)
            }

            Toggle(isOn: Binding(get: { store.config.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                Text("Start at login · \(store.launchAtLoginStatus)")
                    .font(.system(size: design.textSize(9), design: design.bodyFont))
                    .foregroundStyle(design.ink)
            }

            Button("Show config.json in Finder") {
                if let url = store.configStore.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .buttonStyle(.link)
            .font(.system(size: design.textSize(9)))
            .disabled(store.configStore.url == nil)
        }
        .instrumentPlate(design: design)
    }

    private func label(_ text: String) -> some View {
        Text(design.label(text))
            .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
            .tracking(design.tracking(1.3))
            .foregroundStyle(design.secondary)
    }
}

/// One provider's options, its key, and exactly what it reads.
struct ProviderDetailView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let design: DashboardDesign
    let back: () -> Void
    @State private var key = ""
    @State private var keyMessage: String?
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testing = false

    private var descriptor: ProviderDescriptor? { store.descriptor(id) }
    private var config: ProviderConfig { store.config.provider(id) ?? ProviderConfig(id: id, enabled: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: design.spacing) {
            HStack(spacing: 8) {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(BridgeIconButton(design: design))
                    .accessibilityLabel("Back to providers")
                Image(systemName: id.glyph(for: design)).foregroundStyle(design.accent(for: id))
                Text(id.title)
                    .font(.system(size: 17, weight: .medium, design: design.headingFont))
                    .foregroundStyle(design.ink)
                Spacer()
            }

            if let descriptor {
                section("On") {
                    Toggle("Show \(id.title)", isOn: Binding(get: { store.isVisible(id) }, set: { store.setHarness(id, visible: $0) }))
                        .disabled(store.isVisible(id) && !store.canHide(id))
                    Toggle("In the menu bar", isOn: binding(\.inMenuBar))
                    if let reason = store.availability(of: id)?.reason {
                        note(reason, warning: true)
                    }
                }

                section("What Dogwatch reads") {
                    note(descriptor.reads)
                    ForEach(Array(descriptor.commands.enumerated()), id: \.offset) { _, command in
                        note(ProviderDetailText.command(command, in: descriptor), warning: true)
                    }
                    ForEach(ProviderDetailText.prompts(in: descriptor), id: \.self) { text in
                        note(text, warning: true)
                    }
                    if let documentation = descriptor.documentation {
                        Link("Provider documentation", destination: documentation).font(.system(size: design.textSize(9)))
                    }
                }

                if case .pastedKey(let spec) = descriptor.credential {
                    keySection(spec)
                } else if let spec = descriptor.optionalKey {
                    keySection(spec)
                }

                if !descriptor.fields.isEmpty {
                    section("Account") {
                        ForEach(descriptor.fields) { field in
                            switch field.kind {
                            case .text:
                                TextField(field.label, text: Binding(
                                    get: { config.settings[field.id] ?? "" },
                                    set: { value in store.updateConfig { $0.update(id) { $0.settings[field.id] = value.isEmpty ? nil : value } } }),
                                    prompt: Text(field.placeholder))
                                    .textFieldStyle(.roundedBorder)
                            case .toggle:
                                Toggle(field.label, isOn: Binding(
                                    get: { config.settings[field.id] == "true" },
                                    set: { value in store.updateConfig { $0.update(id) { $0.settings[field.id] = value ? "true" : nil } } }))
                            }
                            if let help = field.help { note(help) }
                        }
                    }
                }

                if !descriptor.baseURLs.isEmpty || descriptor.acceptsCustomBaseURL {
                    section("Endpoint") {
                        if !descriptor.baseURLs.isEmpty {
                            Picker("Region", selection: Binding(
                                get: { config.baseURL ?? descriptor.baseURLs[0].url.absoluteString },
                                set: { value in store.updateConfig { $0.update(id) { $0.baseURL = value } } })) {
                                ForEach(descriptor.baseURLs, id: \.url) { option in
                                    Text(option.label).tag(option.url.absoluteString)
                                }
                            }
                        }
                        if descriptor.acceptsCustomBaseURL {
                            TextField("Base URL", text: Binding(
                                get: { config.baseURL ?? "" },
                                set: { value in store.updateConfig { $0.update(id) { $0.baseURL = value.isEmpty ? nil : value } } }),
                                prompt: Text("https://… or http://localhost:4000"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                displaySection(descriptor)

                section("Check") {
                    HStack {
                        Button(testing ? "Testing…" : "Test connection") {
                            testing = true
                            Task {
                                testResult = await store.testConnection(id)
                                testing = false
                            }
                        }
                        .disabled(testing)
                        if store.isCustom(id) {
                            Spacer()
                            Button("Remove provider", role: .destructive) {
                                store.removeCustomProvider(id)
                                back()
                            }
                        }
                    }
                    if let testResult { note(testResult.message, warning: !testResult.ok) }
                }
            }
        }
        .font(.system(size: design.textSize(9), design: design.bodyFont))
        .foregroundStyle(design.ink)
    }

    private func keySection(_ spec: KeySpec) -> some View {
        section(spec.label) {
            if let warning = spec.warning {
                note(warning, warning: true)
            } else if spec.kind == .adminKey {
                note("An \(spec.kind.title.lowercased()) can do more than read usage. Use the narrowest key the provider offers.", warning: true)
            }
            if let advice = spec.advice { note(advice) }
            if spec.kind == .cookie {
                note("A cookie is your signed-in browser session. Anyone with it can act as you on that site; it is kept only in your Keychain.", warning: true)
            }
            SecureField(spec.label, text: $key, prompt: Text(spec.placeholder.isEmpty ? "Paste the \(spec.label.lowercased())" : spec.placeholder))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(spec.label)
            HStack {
                Button("Save") {
                    do {
                        try store.saveKey(key, for: id)
                        key = ""
                        keyMessage = "Stored in your Keychain."
                    } catch {
                        keyMessage = error.localizedDescription
                    }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") {
                    do {
                        try store.removeKey(for: id)
                        keyMessage = "Removed from your Keychain."
                    } catch {
                        keyMessage = error.localizedDescription
                    }
                }
                .disabled(!store.hasKey(id))
                Spacer()
                Text(store.hasKey(id) ? "Stored in Keychain" : "No key set")
                    .foregroundStyle(design.secondary)
            }
            if let keyMessage { note(keyMessage) }
            if let help = spec.helpURL { Link("Create a \(spec.label.lowercased())", destination: help) }
        }
    }

    private func displaySection(_ descriptor: ProviderDescriptor) -> some View {
        let readings = store.states[id]?.snapshot?.readings ?? []
        return section("Display") {
            if !readings.isEmpty {
                Picker("Gauge shows", selection: Binding(
                    get: { config.primary ?? "" },
                    set: { value in store.updateConfig { $0.update(id) { $0.primary = value.isEmpty ? nil : value } } })) {
                    Text("Whatever runs out first").tag("")
                    ForEach(readings) { reading in Text(reading.name).tag(reading.id) }
                }
            }
            Picker("Percentage", selection: Binding(
                get: { config.percentage?.rawValue ?? "" },
                set: { value in store.updateConfig { $0.update(id) { $0.percentage = PercentageMode(rawValue: value) } } })) {
                Text("Like everything else").tag("")
                Text("Left").tag(PercentageMode.left.rawValue)
                Text("Used").tag(PercentageMode.used.rawValue)
            }
            TextField("Label", text: Binding(
                get: { config.label ?? "" },
                set: { value in store.updateConfig { $0.update(id) { $0.label = value.isEmpty ? nil : value } } }),
                prompt: Text("Shown next to the name"))
                .textFieldStyle(.roundedBorder)
            Stepper(value: Binding(get: { config.warnAt ?? 20 }, set: { value in store.updateConfig { $0.update(id) { $0.warnAt = value } } }), in: 0...100, step: 5) {
                Text("Warn at \(config.warnAt ?? 20)% left")
            }
            let minimum = Int((descriptor.minimumRefreshInterval / 60).rounded(.up))
            Stepper(value: Binding(
                get: { Int(store.refreshInterval(for: id) / 60) },
                set: { value in store.updateConfig { $0.update(id) { $0.refreshInterval = TimeInterval(max(value, minimum)) * 60 } } }),
                in: max(1, minimum)...240) {
                Text("Refresh every \(Int(store.refreshInterval(for: id) / 60)) min")
            }
            ForEach(readings.filter { $0.remainingPercent == nil && $0.amount != nil }) { reading in
                TextField("\(reading.name) total", text: Binding(
                    get: { config.limits[reading.id].map { String($0) } ?? "" },
                    set: { value in store.updateConfig { $0.update(id) { $0.limits[reading.id] = Double(value).flatMap { $0 > 0 ? $0 : nil } } } }),
                    prompt: Text("Your allowance or budget, to show a percentage"))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ProviderConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { value in store.updateConfig { $0.update(id) { $0[keyPath: keyPath] = value } } }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Bridge.tight + 2) {
            Text(design.label(title))
                .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                .tracking(design.tracking(1.3))
                .foregroundStyle(design.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPlate(design: design)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(.init(text))
            .font(.system(size: design.textSize(9), design: design.bodyFont))
            .foregroundStyle(warning ? design.warning : design.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A short form for the most common custom provider: one GET, one number. Anything more is
/// written in `config.json` directly; the README documents the format.
private struct CustomProviderForm: View {
    @ObservedObject var store: UsageStore
    let design: DashboardDesign
    let done: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var header = "Authorization"
    @State private var template = "Bearer {key}"
    @State private var kind = "balance"
    @State private var path = ""
    @State private var totalPath = ""
    @State private var unit = "USD"
    @State private var scale = "1"
    @State private var resetPath = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Bridge.stack) {
            HStack {
                Button(action: done) { Image(systemName: "chevron.left") }
                    .buttonStyle(BridgeIconButton(design: design))
                    .accessibilityLabel("Back to providers")
                Text("Custom provider")
                    .font(.system(size: 17, weight: .medium, design: design.headingFont))
            }
            Group {
                TextField("Name", text: $name, prompt: Text("My gateway"))
                TextField("URL", text: $url, prompt: Text("https://api.example.com/v1/balance"))
                HStack {
                    TextField("Header", text: $header)
                    TextField("Value", text: $template)
                }
                Picker("Kind", selection: $kind) {
                    Text("Balance").tag("balance")
                    Text("Spend").tag("spend")
                    Text("Used %").tag("window")
                }
                .pickerStyle(.segmented)
                TextField("Path", text: $path, prompt: Text(kind == "window" ? "data.used_percent" : kind == "spend" ? "data.usage_monthly" : "data.balance"))
                if kind != "window" {
                    TextField("Total path (optional)", text: $totalPath, prompt: Text(kind == "spend" ? "data.budget" : "data.limit"))
                    HStack {
                        TextField("Unit", text: $unit, prompt: Text("USD, credits"))
                        TextField("Scale", text: $scale, prompt: Text("0.01 for cents"))
                    }
                }
                TextField("Reset date path (optional)", text: $resetPath)
            }
            .textFieldStyle(.roundedBorder)
            Text("Use {key} in the header value; the key itself goes in the Keychain from the provider's settings afterwards. The URL must be https, or http on localhost.")
                .font(.system(size: design.textSize(8)))
                .foregroundStyle(design.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.system(size: design.textSize(9))).foregroundStyle(design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Add") { add() }.disabled(name.isEmpty || url.isEmpty || path.isEmpty)
            }
        }
        .font(.system(size: design.textSize(9), design: design.bodyFont))
        .foregroundStyle(design.ink)
        .instrumentPlate(design: design)
    }

    private func add() {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        var reading: [String: JSONValue] = ["id": .string(kind), "name": .string(name), "kind": .string(kind)]
        switch kind {
        case "window": reading["usedPercent"] = .string(path)
        case "spend": reading["amount"] = .string(path); if !totalPath.isEmpty { reading["budget"] = .string(totalPath) }
        default: reading["remaining"] = .string(path); if !totalPath.isEmpty { reading["total"] = .string(totalPath) }
        }
        if kind != "window" {
            reading["unit"] = .string(unit.isEmpty ? "USD" : unit)
            if let value = Double(scale), value != 1 { reading["scale"] = .number(value) }
        }
        if !resetPath.isEmpty { reading["reset"] = .string(resetPath) }
        var object: [String: JSONValue] = [
            "id": .string("custom-\(slug.isEmpty ? "provider" : slug)"),
            "name": .string(name),
            "url": .string(url),
            "readings": .array([.object(reading)]),
        ]
        if !header.isEmpty, !template.isEmpty { object["headers"] = .object([header: .string(template)]) }
        do {
            try store.addCustomProvider(.object(object))
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct DeckToggleStyle: ToggleStyle {
    let accent: Color
    let design: DashboardDesign

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: design.isTerminal ? 2 : 11)
                    .fill(configuration.isOn ? accent : design.ink.opacity(0.14))
                RoundedRectangle(cornerRadius: design.isTerminal ? 1 : 9)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(knob(isOn: configuration.isOn))
                    .padding(2)
            }
            .frame(width: 38, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: design.isTerminal ? 2 : 11)
                    .stroke(design.border, lineWidth: 1)
            )
            .animation(Bridge.ease(0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "Visible" : "Hidden")
    }

    private func knob(isOn: Bool) -> Color {
        switch design {
        case .nautical, .ledger: return isOn ? design.background : design.ink.opacity(0.7)
        case .cyber: return design.background
        }
    }
}

/// The warnings a provider's settings show, from what it declares.
enum ProviderDetailText {
    private static func toggleLabel(_ id: String?, in descriptor: ProviderDescriptor) -> String? {
        guard let id else { return nil }
        return descriptor.fields.first { $0.id == id }?.label ?? id
    }

    static func command(_ command: DeclaredCommand, in descriptor: ProviderDescriptor) -> String {
        let line = "`\(([command.executable] + command.arguments).joined(separator: " "))`"
        if let toggle = toggleLabel(command.onlyWhen, in: descriptor) {
            return "With “\(toggle)” on, Dogwatch runs \(line): \(command.reason)"
        }
        return "Turning this provider on runs \(line): \(command.reason)"
    }

    /// One line per source that can show a Keychain prompt: the credential or any local source.
    static func prompts(in descriptor: ProviderDescriptor) -> [String] {
        var stores = descriptor.localSources
        if case .toolStore(let store) = descriptor.credential { stores.insert(store, at: 0) }
        return stores.filter(\.mayPrompt).map { store in
            let when = toggleLabel(store.onlyWhen, in: descriptor).map { "With “\($0)” on, " } ?? ""
            let reading = when.isEmpty ? "Reading" : "reading"
            return "\(when)\(reading) \(store.location) makes macOS ask whether Dogwatch may use it. If you deny it, Dogwatch asks again only when you press Refresh."
        }
    }
}
