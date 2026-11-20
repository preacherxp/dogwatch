import AppKit
import SwiftUI

@main
struct DogwatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var usageStore = UsageStore.live()

    var body: some Scene {
        MenuBarExtra {
            NauticalDashboardView(store: usageStore)
        } label: {
            // A MenuBarExtra label shows only its first image and text, so the whole row is
            // drawn into one template image. SwiftUI re-evaluates this when any input changes.
            let entries = usageStore.menuBarEntries
            let text = MenuBarLabel.accessibilityText(entries)
            Image(nsImage: MenuBarLabel.image(entries: entries, design: usageStore.config.theme))
                .accessibilityLabel(text)
                .help(text)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarEntry: Equatable {
    let provider: ProviderID
    let value: String

    var accessibilityText: String {
        switch value {
        case "—": return "\(provider.title) no reading yet"
        case "…": return "\(provider.title) loading"
        default: return "\(provider.title) \(value) \(value.hasSuffix("%") ? "remaining" : "left")"
        }
    }
}

enum MenuBarLabel {
    /// The visible providers in the given order, each with the value the menu bar shows.
    static func entries(order: [ProviderID], value: (ProviderID) -> String) -> [MenuBarEntry] {
        order.map { MenuBarEntry(provider: $0, value: value($0)) }
    }

    /// The three original providers that are visible, in their old order.
    static func entries(visibility: HarnessVisibility, value: (ProviderID) -> String) -> [MenuBarEntry] {
        entries(order: HarnessVisibility.legacyProviders.filter { visibility.isVisible($0) }, value: value)
    }

    /// The widest the row may get, in points. Providers past it are left out of the image (the
    /// spoken text still lists every one); set `menuBar.maxItems` to choose which.
    static let maximumWidth: CGFloat = 420

    static func accessibilityText(_ entries: [MenuBarEntry]) -> String {
        entries.map(\.accessibilityText).joined(separator: ", ")
    }

    /// The row as a template image, so macOS tints it for light and dark menu bars and the
    /// highlighted state. Drawn at the screen's scale and sized in points.
    @MainActor
    static func image(entries: [MenuBarEntry], design: DashboardDesign, scale: CGFloat? = nil) -> NSImage {
        let scale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        var shown = entries
        var rendered: CGImage?
        repeat {
            let renderer = ImageRenderer(content: MenuBarRow(design: design, entries: shown))
            renderer.scale = scale
            rendered = renderer.cgImage
            guard let width = rendered?.width, CGFloat(width) / scale > maximumWidth, shown.count > 1 else { break }
            shown.removeLast()
        } while true
        guard let cgImage = rendered else { return NSImage() }
        let image = NSImage(cgImage: cgImage, size: NSSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        ))
        image.isTemplate = true
        image.accessibilityDescription = accessibilityText(entries)
        return image
    }
}

struct MenuBarRow: View {
    let design: DashboardDesign
    let entries: [MenuBarEntry]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(entries, id: \.provider) { entry in
                // Opaque black: a template image uses only the alpha channel.
                MenuBarProviderLabel(design: design, harness: entry.provider, value: entry.value, ink: .black)
            }
        }
    }
}

struct MenuBarProviderLabel: View {
    let design: DashboardDesign
    let harness: ProviderID
    let value: String
    var ink: Color = .primary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: harness.glyph(for: design))
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .fixedSize()
        .help("\(harness.title): \(value) remaining")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(harness.title), \(value) remaining")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
