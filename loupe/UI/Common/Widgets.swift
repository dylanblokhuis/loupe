import Combine
import SwiftUI

extension ResourceHealth {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .pending: return .blue
        case .terminating: return .purple
        case .unknown: return .secondary
        }
    }

    var label: String {
        switch self {
        case .ok: return "Healthy"
        case .warning: return "Degraded"
        case .error: return "Failing"
        case .pending: return "Pending"
        case .terminating: return "Terminating"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        case .terminating: return "trash.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct HealthDot: View {
    let health: ResourceHealth
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(health.color.opacity(health == .unknown ? 0.45 : 1))
            .frame(width: size, height: size)
            .help(health.label)
    }
}

/// A small pill used for labels, statuses and counts.
struct Chip: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

/// Key/value grid used throughout the detail inspector.
struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            content
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1.5)
    }
}

extension DetailRow where Content == Text {
    init(_ label: String, _ value: String) {
        self.label = label
        self.content = Text(value.isEmpty ? "—" : value)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    var systemImage: String?
    @State private var expanded = true
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            .padding(.top, 6)
            .padding(.leading, 2)
        } label: {
            Label {
                Text(title).font(.system(size: 12, weight: .semibold))
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .foregroundStyle(.primary)
        }
        .padding(.vertical, 6)
    }
}

/// Wrapping flow layout for label chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            origin.x += size.width + spacing
            maxWidth = max(maxWidth, origin.x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxWidth, width), height: origin.y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    var message: String?
    var systemImage: String = "tray"
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Horizontal capacity bar used for CPU/memory/pod usage.
struct UsageBar: View {
    let value: Double
    let total: Double
    var tint: Color = .accentColor
    /// Load bars turn amber and red as they fill; completion bars ("4 of 4
    /// nodes ready") keep their tint, because full is the good outcome.
    var warnsWhenFull = true

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(warnsWhenFull
                          ? (fraction > 0.9 ? Color.red : (fraction > 0.75 ? Color.orange : tint))
                          : tint)
                    .frame(width: max(2, geometry.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var systemImage: String?
    var tint: Color = .accentColor
    var progress: (value: Double, total: Double)?
    var progressWarnsWhenFull = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10)).foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let progress {
                UsageBar(
                    value: progress.value, total: progress.total,
                    tint: tint, warnsWhenFull: progressWarnsWhenFull
                )
            }
            if let caption {
                Text(caption).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Live-updating age text so tables tick without a re-fetch.
struct AgeText: View {
    let date: Date?
    @State private var now = Date()

    private static let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(Age.short(since: date, now: now))
            .monospacedDigit()
            .help(Age.absolute(date))
            .onReceive(Self.ticker) { now = $0 }
    }
}
