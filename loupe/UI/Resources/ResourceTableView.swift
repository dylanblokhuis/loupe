import SwiftUI

/// A column as rendered on screen — either one the API server described, or the
/// Namespace column the app adds when browsing across namespaces.
struct DisplayColumn: Identifiable, Hashable {
    enum Source: Hashable {
        case namespace
        case server(index: Int)
    }

    /// Distinct from the title: a custom resource may print two columns with
    /// the same name, and `ForEach` needs them to be tellable apart.
    var id: String
    var title: String
    var source: Source
    var description: String = ""
    var weight: Double = 1

    func value(for row: ResourceRow) -> String {
        switch source {
        case .namespace:
            return row.object.namespace ?? "—"
        case .server(let index):
            return row.cells.indices.contains(index) ? row.cells[index] : ""
        }
    }
}

/// A compact, virtualised table with sortable headers and proportional columns.
///
/// SwiftUI's `Table` cannot express columns that are only known at runtime, so
/// the table is drawn directly: a header row plus a `List` of rows sharing one
/// set of computed widths.
struct ResourceTableView: View {
    let columns: [DisplayColumn]
    let rows: [ResourceRow]
    @Binding var selection: String?
    @Binding var sortColumn: String?
    @Binding var sortAscending: Bool
    /// False for kinds that report no state at all, so the leading dot — which
    /// could only ever be grey — is left out along with the room it takes.
    var showsHealth: Bool = true
    var onActivate: (ResourceRow) -> Void
    @ViewBuilder var rowMenu: (ResourceRow) -> AnyView

    var body: some View {
        GeometryReader { geometry in
            let widths = Self.widths(
                for: columns, rows: rows, available: geometry.size.width - 24, showsHealth: showsHealth
            )
            VStack(spacing: 0) {
                header(widths: widths)
                Divider()
                List(selection: $selection) {
                    ForEach(rows) { row in
                        RowView(row: row, columns: columns, widths: widths, showsHealth: showsHealth)
                            .tag(row.id)
                            .contentShape(Rectangle())
                            // A `List` alone opens a row only on a double click,
                            // and re-clicking the selected row changes nothing for
                            // its selection binding to react to. Driving both from
                            // one tap means a single click anywhere along the row
                            // opens it, every time.
                            .onTapGesture {
                                selection = row.id
                                onActivate(row)
                            }
                            .contextMenu { rowMenu(row) }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
                .environment(\.defaultMinListRowHeight, 24)
            }
        }
    }

    private func header(widths: [CGFloat]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                Button {
                    if sortColumn == column.id {
                        sortAscending.toggle()
                    } else {
                        sortColumn = column.id
                        sortAscending = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(column.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if sortColumn == column.id {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(column.description.isEmpty ? column.title : column.description)
                .frame(width: widths[index], alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// Sizes columns from the width their content actually needs, then hands
    /// out the leftover space — mostly to the name column, but not all of it,
    /// so a wide window does not leave every other column cramped.
    static func widths(
        for columns: [DisplayColumn],
        rows: [ResourceRow],
        available: CGFloat,
        showsHealth: Bool = true
    ) -> [CGFloat] {
        guard !columns.isEmpty else { return [] }
        let characterWidth: CGFloat = 6.9
        let sampled = rows.prefix(200)

        var natural: [CGFloat] = columns.enumerated().map { index, column in
            // Headers are semibold and carry a sort chevron, so they need a
            // little more room per character than the cells below them.
            var characters = Double(column.title.count) + 3
            for row in sampled {
                characters = max(characters, Double(column.value(for: row).count))
            }
            let content = CGFloat(min(max(characters, 5), 44)) * characterWidth + 12
            // The first column also carries the health dot, when there is one.
            return index == 0 && showsHealth ? content + 22 : content
        }

        let spacing = CGFloat(columns.count - 1) * 8
        let usable = max(240, available - spacing)
        let total = natural.reduce(0, +)

        if total > usable {
            let scale = usable / total
            return natural.map { max(40, $0 * scale) }
        }

        var surplus = usable - total
        if columns.count > 1 {
            let leadShare = surplus * 0.45
            natural[0] += leadShare
            surplus -= leadShare
            let restTotal = natural.dropFirst().reduce(0, +)
            if restTotal > 0 {
                for index in 1..<natural.count {
                    natural[index] += surplus * (natural[index] / restTotal)
                }
            }
        } else {
            natural[0] += surplus
        }
        return natural
    }

    private struct RowView: View {
        let row: ResourceRow
        let columns: [DisplayColumn]
        let widths: [CGFloat]
        let showsHealth: Bool

        var body: some View {
            HStack(spacing: 8) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    cell(column, at: index)
                        .frame(width: widths[index], alignment: .leading)
                }
                // Claims any width the columns left over, so a click lands on
                // the row no matter how far right it falls.
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20)
        }

        @ViewBuilder
        private func cell(_ column: DisplayColumn, at index: Int) -> some View {
            let text = column.value(for: row)
            if index == 0 {
                HStack(spacing: 6) {
                    if showsHealth {
                        HealthDot(health: row.object.health, size: row.object.health == .unknown ? 5 : 8)
                    }
                    Text(text)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.object.isTerminating {
                        Text("terminating")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.purple)
                    }
                }
            } else if column.title.caseInsensitiveCompare("Age") == .orderedSame {
                AgeText(date: row.object.creationTimestamp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(text.isEmpty ? "—" : text)
                    .font(.system(size: 11))
                    .foregroundStyle(tint(for: column, value: text) ?? .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        /// Highlights the handful of cell values that carry meaning at a glance.
        private func tint(for column: DisplayColumn, value: String) -> Color? {
            guard column.title.caseInsensitiveCompare("Status") == .orderedSame
                || column.title.caseInsensitiveCompare("State") == .orderedSame
                || column.title.caseInsensitiveCompare("Ready") == .orderedSame
            else { return nil }
            switch value {
            case "Running", "Active", "Succeeded", "Bound", "Complete", "True", "Ready", "Available":
                return .green
            case "Pending", "ContainerCreating", "PodInitializing", "Terminating", "Progressing":
                return .orange
            case "Failed", "CrashLoopBackOff", "Error", "ImagePullBackOff", "ErrImagePull",
                 "Evicted", "OOMKilled", "NotReady", "Unknown":
                return .red
            default:
                // `2/3` style readiness cells: green only when fully ready.
                if column.title.caseInsensitiveCompare("Ready") == .orderedSame,
                   value.contains("/") {
                    let parts = value.split(separator: "/")
                    if parts.count == 2, let ready = Int(parts[0]), let total = Int(parts[1]) {
                        if total == 0 { return .secondary }
                        return ready == total ? .green : (ready == 0 ? .red : .orange)
                    }
                }
                return nil
            }
        }
    }
}
