import SwiftUI

/// Looks up any provider's descriptor by id: the built-in ones and the user's custom ones. Views
/// use it through `ProviderID`'s display properties, so they never need to know a provider.
final class ProviderDirectory {
    static let shared = ProviderDirectory(ProviderRegistry.builtIn.map(\.descriptor))

    private let lock = NSLock()
    private var descriptors: [ProviderID: ProviderDescriptor] = [:]

    init(_ list: [ProviderDescriptor]) {
        register(list)
    }

    func register(_ list: [ProviderDescriptor]) {
        lock.lock(); defer { lock.unlock() }
        for descriptor in list { descriptors[descriptor.id] = descriptor }
    }

    func descriptor(_ id: ProviderID) -> ProviderDescriptor? {
        lock.lock(); defer { lock.unlock() }
        return descriptors[id]
    }
}

extension ProviderID {
    private var descriptor: ProviderDescriptor? { ProviderDirectory.shared.descriptor(self) }

    var title: String { descriptor?.name ?? rawValue.capitalized }
    var logbookName: String { title.uppercased() }
    var iconName: String { descriptor?.glyph.symbol ?? "gauge.with.dots.needle.33percent" }
    var tint: Color { descriptor?.tint ?? Bridge.muted }
    var summary: String { descriptor?.summary ?? "" }
    var category: ProviderCategory { descriptor?.category ?? .api }

    func glyph(for design: DashboardDesign) -> String {
        descriptor?.glyph.symbol(for: design) ?? iconName
    }
}
