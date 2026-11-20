import SwiftUI

/// Nautical: a ship's bridge on a night watch. Near-neutral night surfaces, binnacle-cream text,
/// brass as instrument material, one dial colour per provider and coral for low allowance.
enum Bridge {
    static let cream = Color(red: 0.93, green: 0.90, blue: 0.83)
    static let secondaryText = Color(red: 0.66, green: 0.69, blue: 0.68)
    static let muted = Color(red: 0.49, green: 0.54, blue: 0.54)
    static let seafoam = Color(red: 0.16, green: 0.87, blue: 0.73)
    static let coral = Color(red: 0.90, green: 0.40, blue: 0.35)
    static let brass = Color(red: 0.82, green: 0.64, blue: 0.26)
    static let amber = Color(red: 0.98, green: 0.65, blue: 0.20)
    static let sky = Color(red: 0.30, green: 0.62, blue: 1.0)
    static let deep = Color(red: 0.043, green: 0.063, blue: 0.075)
    static let well = Color(red: 0.067, green: 0.094, blue: 0.110)
    static let raised = Color(red: 0.094, green: 0.129, blue: 0.149)
    static let hairline = cream.opacity(0.08)

    static let plateRadius: CGFloat = 12
    static let windowWidth: CGFloat = 378
    static let inset: CGFloat = 16
    static let stack: CGFloat = 8
    static let tight: CGFloat = 4
    static let platePad: CGFloat = 12

    static func tint(for provider: ProviderID) -> Color {
        provider.tint
    }

    /// The one easing curve every transition uses.
    static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }
}

struct InstrumentPlate: ViewModifier {
    var design: DashboardDesign = .nautical
    var padding: CGFloat = Bridge.platePad

    func body(content: Content) -> some View {
        switch design {
        case .cyber:
            content
                .padding(12)
                .background(design.surface, in: ChamferShape())
                .overlay(ChamferShape().stroke(design.border, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    design.brand.frame(width: 26, height: 3)
                }
        case .ledger:
            content
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    design.border.frame(height: 1)
                }
        case .nautical:
            content
                .padding(padding)
                .background(Bridge.well, in: RoundedRectangle(cornerRadius: Bridge.plateRadius))
                .overlay(RoundedRectangle(cornerRadius: Bridge.plateRadius).strokeBorder(Bridge.hairline, lineWidth: 1))
        }
    }
}

struct DesignHeading: View {
    let design: DashboardDesign
    let eyebrow: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        if design == .ledger {
            masthead
        } else {
            banner
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(eyebrow)
                Spacer(minLength: 8)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(design.secondary)
            Text(title)
                .font(.system(size: 30, design: .serif))
                .tracking(-0.5)
                .foregroundStyle(design.ink)
                .fixedSize(horizontal: false, vertical: true)
            DoubleRule(color: design.ink.opacity(0.4))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(design.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(eyebrow.uppercased())
                    .tracking(1.1)
                Spacer(minLength: 0)
                if design.isTerminal {
                    Image(systemName: "waveform.path")
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(design.brand)
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: design.headingFont))
                    .tracking(design.isTerminal ? -1.5 : -0.8)
                    .foregroundStyle(design.ink)
                    // Chromatic split: red ghost left, cyan ghost right.
                    .shadow(color: design == .cyber ? design.warning : .clear, radius: 0, x: -1.5)
                    .shadow(color: design == .cyber ? design.accent(for: .codex) : .clear, radius: 0, x: 1.5)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, design: design.bodyFont))
                    .foregroundStyle(design.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }
}

/// The bookkeeper's double underline that closes a column of figures.
struct DoubleRule: View {
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            color.frame(height: 1)
            color.frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

struct DesignBackdrop: View {
    let design: DashboardDesign

    var body: some View {
        ZStack {
            design.background
            switch design {
            case .cyber:
                CyberBackdrop()
            case .ledger:
                // Faint paper ruling.
                Canvas { context, size in
                    var lines = Path()
                    for y in stride(from: CGFloat.zero, through: size.height, by: 4) {
                        lines.move(to: CGPoint(x: 0, y: y))
                        lines.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(lines, with: .color(design.ink.opacity(0.018)), lineWidth: 0.5)
                }
            case .nautical:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func instrumentPlate(design: DashboardDesign = .nautical, padding: CGFloat = Bridge.platePad) -> some View {
        modifier(InstrumentPlate(design: design, padding: padding))
    }
}

struct BridgeIconButton: ButtonStyle {
    var design: DashboardDesign = .nautical

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(design.ink.opacity(configuration.isPressed ? 0.45 : 0.82))
            .frame(width: 28, height: 24)
            .background(
                design == .nautical ? Bridge.raised : design.ink.opacity(configuration.isPressed ? 0.14 : 0.05),
                in: RoundedRectangle(cornerRadius: design.controlRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: design.controlRadius)
                    .stroke(design.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Bridge.ease(0.14), value: configuration.isPressed)
    }
}

/// Rectangle with the top-right and bottom-left corners cut off.
struct ChamferShape: Shape {
    var cut: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
            path.closeSubpath()
        }
    }
}

private struct CyberBackdrop: View {
    private let design = DashboardDesign.cyber

    var body: some View {
        ZStack {
            Canvas { context, size in
                var scanlines = Path()
                for y in stride(from: CGFloat.zero, through: size.height, by: 3) {
                    scanlines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                }
                context.fill(scanlines, with: .color(.white.opacity(0.022)))

                var hazard = Path()
                for x in stride(from: CGFloat(-8), through: size.width, by: 14) {
                    hazard.move(to: CGPoint(x: x + 4, y: 0))
                    hazard.addLine(to: CGPoint(x: x + 11, y: 0))
                    hazard.addLine(to: CGPoint(x: x + 7, y: 4))
                    hazard.addLine(to: CGPoint(x: x, y: 4))
                    hazard.closeSubpath()
                }
                context.fill(hazard, with: .color(design.brand))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

struct DesignSegmentedPicker<Option: Identifiable & Equatable>: View {
    let design: DashboardDesign
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: design.textSize(8), weight: design.labelWeight, design: design.bodyFont))
                        .tracking(design.tracking(0.8))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .foregroundStyle(selection == option ? design.selectionInk : design.secondary)
                        .background(
                            selection == option ? design.selectionFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: design.controlRadius)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: design.controlRadius)
                                .stroke(selection == option ? design.border : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(design.surface, in: RoundedRectangle(cornerRadius: design.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: design.controlRadius)
                .stroke(design.border, lineWidth: 1)
        )
    }
}
