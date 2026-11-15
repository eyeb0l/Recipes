import RecipeCore
import SwiftUI

/// The app's "kitchen notebook" design language: warm paper, ink, and a single paprika accent,
/// with system Liquid Glass reserved for controls that float above content.
enum RecipeTheme {
    static let paper = Color(light: 0xF5EFE4, dark: 0x12100E)
    static let surface = Color(light: 0xFFFBF4, dark: 0x1D1A16)
    static let ink = Color(light: 0x221B15, dark: 0xF4EDE3)
    static let secondaryInk = Color(light: 0x6B6055, dark: 0xB0A598)
    static let grid = Color(light: 0xDACDB8, dark: 0x463E35)
    static let gridSubtle = Color(light: 0xEAE1D3, dark: 0x2E2924)
    static let stage = Color(light: 0xEFE6D8, dark: 0x2A2520)
    static let stageAlternate = Color(light: 0xE8DDCB, dark: 0x322C26)
    static let timelineStage = Color(light: 0xEDE2D2, dark: 0x2F2924)
    static let timelineStageAlternate = Color(light: 0xE5D8C4, dark: 0x37302A)
    static let timelineStageBorder = Color(light: 0xCFBFA8, dark: 0x554A3F)
    /// Paprika: the one accent colour, used for primary actions and the current step.
    static let focus = Color(light: 0xB94A2C, dark: 0xF0875F)
    static let focusText = Color(light: 0x8F3418, dark: 0xF6A585)
    /// Text and icons placed on a solid paprika fill; meets WCAG AA in both appearances.
    static let onFocus = Color(light: 0xFFFFFF, dark: 0x1D1A16)
    static let warning = Color(light: 0x995708, dark: 0xEDB45C)
    static let success = Color(light: 0x4C6B43, dark: 0x9DC78E)

    /// Muted tile colours for recipe monograms, chosen deterministically from the title.
    static let monogramTints: [Color] = [
        Color(light: 0xE6CDB8, dark: 0x4A3427),
        Color(light: 0xD5DCC4, dark: 0x343D2C),
        Color(light: 0xE9D7AE, dark: 0x4A3E22),
        Color(light: 0xD9CBD9, dark: 0x3D3140),
        Color(light: 0xC9D8DA, dark: 0x2B3A3D)
    ]

    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .serif, weight: weight)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    func editorialSurface() -> some View {
        foregroundStyle(RecipeTheme.ink)
            .background(RecipeTheme.paper.ignoresSafeArea())
            .tint(RecipeTheme.focus)
    }

    /// The app's primary action: a paprika Liquid Glass button with legible label colour.
    func primaryGlassButton() -> some View {
        buttonStyle(.glassProminent)
            .tint(RecipeTheme.focus)
            .foregroundStyle(RecipeTheme.onFocus)
    }

    /// A raised paper card with a hairline border.
    func paperCard(cornerRadius: CGFloat = 18, isHighlighted: Bool = false) -> some View {
        background(RecipeTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isHighlighted ? RecipeTheme.focus : RecipeTheme.gridSubtle, lineWidth: isHighlighted ? 1.5 : 1)
            }
    }
}

/// A small uppercase label that introduces a section, in the style of a printed cookbook.
struct EyebrowLabel: View {
    let text: String
    var color: Color = RecipeTheme.secondaryInk

    init(_ text: String, color: Color = RecipeTheme.secondaryInk) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

/// A section title paired with an optional trailing accessory.
struct SectionTitle<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(RecipeTheme.display(.title2))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            accessory
        }
    }
}

/// A compact fact about a recipe, such as its total time or number of stages.
struct MetricChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(RecipeTheme.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RecipeTheme.stage, in: Capsule())
    }
}

/// A typeset initial on a muted tile, giving each recipe a recognisable mark without photography.
struct RecipeMonogram: View {
    let title: String
    var size: CGFloat = 52

    var body: some View {
        let initial = title.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "R"
        Text(initial)
            .font(.system(size: size * 0.5, weight: .semibold, design: .serif))
            .foregroundStyle(RecipeTheme.ink.opacity(0.82))
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        // A stable hash: Swift's hashValue is seeded per launch.
        let sum = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return RecipeTheme.monogramTints[sum % RecipeTheme.monogramTints.count]
    }
}

extension UnitSystemPreference {
    var displayName: String {
        switch self {
        case .source: "As written"
        case .metric: "Metric"
        case .imperial: "Imperial"
        }
    }
}

extension RecipeSourceType {
    var displayName: String {
        switch self {
        case .url: "Web"
        case .text: "Pasted"
        case .images: "Cookbook"
        case .manual: "Manual"
        case .sample: "Sample"
        }
    }

    var systemImage: String {
        switch self {
        case .url: "globe"
        case .text: "doc.plaintext"
        case .images: "book"
        case .manual: "square.and.pencil"
        case .sample: "sparkles"
        }
    }
}

/// App-wide display preferences that persist between launches.
enum AppPreferenceKey {
    static let unitSystem = "preferredUnitSystem"
    static let librarySort = "librarySort"
}

/// Lays out children left to right, wrapping to a new line when the next child would not fit.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if proposedWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? min(size.width, maxWidth) : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
