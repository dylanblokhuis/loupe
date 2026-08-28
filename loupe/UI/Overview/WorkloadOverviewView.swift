import Foundation
import SwiftUI

/// Workloads › Overview: a health ring per workload kind the cluster serves,
/// plus the most recent events in the current namespace scope.
struct WorkloadOverviewView: View {
    let connection: ClusterConnection
    @Binding var inspection: InspectionTarget?

    @State private var model = WorkloadOverviewModel()
    @State private var refreshTick = 0

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                Banner(message: message, tint: .red) { model.errorMessage = nil }
            }
            content
        }
        .navigationTitle("Workloads")
        .toolbar { toolbarContent }
        .task(id: refreshKey) {
            while !Task.isCancelled {
                await model.load(connection: connection)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Namespace scope plus the manual refresh counter. Bumping the counter
    /// cancels the running fetch and starts a fresh one, so every request this
    /// page makes is owned by the view and dies when the view goes away.
    private var refreshKey: String {
        "\(refreshTick)|" + connection.selectedNamespaces.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.summaries.isEmpty, model.events.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading workloads…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.summaries.isEmpty, model.events.isEmpty {
            EmptyStateView(
                title: "No workloads",
                message: "Nothing to summarise in \(scopeDescription.lowercased()).",
                systemImage: "shippingbox",
                action: ("Refresh", { refresh() })
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    rings
                    if !model.unavailable.isEmpty {
                        Label(
                            "Not listable here: \(model.unavailable.joined(separator: ", "))",
                            systemImage: "eye.slash"
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }
                    eventsCard
                }
                .padding(14)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Health").font(.system(size: 12, weight: .semibold))
            Text(scopeDescription).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.isLoading {
                ProgressView().controlSize(.mini)
            } else if let updated = model.lastUpdated {
                Text("updated \(Age.short(since: updated)) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rings: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 12)],
            spacing: 12
        ) {
            ForEach(model.summaries) { summary in
                kindCard(summary)
            }
        }
    }

    private func kindCard(_ summary: WorkloadOverviewModel.KindSummary) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: NavigationCatalog.icon(for: summary.resource))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(summary.resource.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            HealthRing(slices: summary.slices, total: summary.total)
                .frame(width: 92, height: 92)
                .overlay {
                    Text("\(summary.total)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: 60)
                }
                .padding(.vertical, 2)
            legend(for: summary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func legend(for summary: WorkloadOverviewModel.KindSummary) -> some View {
        if summary.slices.isEmpty {
            Text("none").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(summary.slices) { slice in
                    HStack(spacing: 3) {
                        HealthDot(health: slice.health, size: 6)
                        Text("\(slice.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                        Text(slice.health.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .help(slice.health.label)
                }
            }
        }
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bell").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Events").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.warningCount > 0 {
                    Chip(
                        text: model.warningCount == 1 ? "1 warning" : "\(model.warningCount) warnings",
                        color: .orange
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if model.events.isEmpty {
                Text(model.eventsAvailable ? "No recent events in scope." : "Events are not listable here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().opacity(0.4) }
                    eventRow(event)
                }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func eventRow(_ event: KubeObject) -> some View {
        let tint = WorkloadOverviewModel.tint(for: event)
        let reason = event.raw.string(at: "reason") ?? "Event"
        let count = event.raw.int(at: "count") ?? 0
        let message = event.raw.string(at: "message") ?? ""

        return Button {
            inspection = InspectionTarget(object: event, resource: model.eventResource)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(reason)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        Text(WorkloadOverviewModel.involvedDescription(event))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if count > 1 {
                            Text("×\(count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 4)
                        AgeText(date: WorkloadOverviewModel.timestamp(event))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var scopeDescription: String {
        guard let namespaces = connection.effectiveNamespaces else { return "All namespaces" }
        if namespaces.count > 3 { return "\(namespaces.count) namespaces" }
        return namespaces.joined(separator: ", ")
    }

    private func refresh() {
        refreshTick &+= 1
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.isLoading)
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class WorkloadOverviewModel {
    struct HealthSlice: Identifiable, Sendable {
        var health: ResourceHealth
        var count: Int
        var id: Int { health.sortOrder }
    }

    struct KindSummary: Identifiable, Sendable {
        var resource: APIResource
        var total: Int
        var slices: [HealthSlice]
        var id: String { resource.stableKey }
    }

    private(set) var summaries: [KindSummary] = []
    private(set) var events: [KubeObject] = []
    private(set) var eventResource: APIResource?
    private(set) var eventsAvailable = false
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    /// Kinds the cluster serves but this user cannot list.
    private(set) var unavailable: [String] = []
    var errorMessage: String?

    /// Bumped by every load so a superseded one cannot publish stale results.
    private var generation = 0

    /// Lens's workload set, in the order the sidebar lists them.
    private static let kinds: [(kind: String, group: String)] = [
        ("Pod", ""),
        ("Deployment", "apps"),
        ("DaemonSet", "apps"),
        ("StatefulSet", "apps"),
        ("ReplicaSet", "apps"),
        ("Job", "batch"),
        ("CronJob", "batch"),
    ]

    private static let eventLimit = 20

    func load(connection: ClusterConnection) async {
        guard let client = connection.client else { return }
        // A load that has been replaced must neither publish its results nor
        // clear the spinner belonging to the one that replaced it. Refusing to
        // start while another is in flight would instead let a cancelled fetch
        // suppress its own replacement.
        generation &+= 1
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }

        let namespaces = connection.effectiveNamespaces
        let resources = Self.kinds.compactMap { connection.catalog.resource(kind: $0.kind, group: $0.group) }
        let eventResource = connection.catalog.resource(kind: "Event", group: "")
        self.eventResource = eventResource
        eventsAvailable = eventResource != nil

        guard !resources.isEmpty || eventResource != nil else {
            summaries = []
            events = []
            errorMessage = nil
            return
        }

        let outcomes = await withTaskGroup(of: WorkloadFetch.Outcome.self) { group in
            for resource in resources {
                group.addTask {
                    await WorkloadFetch.load(
                        key: resource.stableKey, client: client, resource: resource,
                        namespaces: namespaces, cap: 5_000
                    )
                }
            }
            if let eventResource {
                group.addTask {
                    await WorkloadFetch.load(
                        key: "events", client: client, resource: eventResource,
                        namespaces: namespaces, cap: 2_000
                    )
                }
            }
            var collected: [String: WorkloadFetch.Outcome] = [:]
            for await outcome in group { collected[outcome.key] = outcome }
            return collected
        }

        guard token == generation, !Task.isCancelled else { return }

        var built: [KindSummary] = []
        var skipped: [String] = []
        var failures: [String] = []
        for resource in resources {
            guard let outcome = outcomes[resource.stableKey] else { continue }
            if let failure = outcome.failure {
                skipped.append(resource.displayName)
                failures.append("\(resource.displayName): \(failure)")
                continue
            }
            built.append(Self.summarize(resource: resource, objects: outcome.objects))
        }

        summaries = built
        unavailable = skipped

        if let eventOutcome = outcomes["events"] {
            if eventOutcome.failure != nil {
                eventsAvailable = false
                events = []
            } else {
                events = eventOutcome.objects
                    .sorted { (Self.timestamp($0) ?? .distantPast) > (Self.timestamp($1) ?? .distantPast) }
                    .prefix(Self.eventLimit)
                    .map { $0 }
            }
        } else {
            events = []
        }

        // Only shout when nothing at all came back; a single forbidden kind is a footnote.
        errorMessage = built.isEmpty && !failures.isEmpty ? failures.joined(separator: " · ") : nil
        lastUpdated = Date()
    }

    var warningCount: Int {
        events.filter { $0.raw.string(at: "type") == "Warning" }.count
    }

    private static func summarize(resource: APIResource, objects: [KubeObject]) -> KindSummary {
        var counts: [ResourceHealth: Int] = [:]
        for object in objects { counts[object.health, default: 0] += 1 }
        let slices = counts
            .filter { $0.value > 0 }
            .map { HealthSlice(health: $0.key, count: $0.value) }
            .sorted { $0.health.sortOrder < $1.health.sortOrder }
        return KindSummary(resource: resource, total: objects.count, slices: slices)
    }

    nonisolated static func timestamp(_ event: KubeObject) -> Date? {
        KubeDate.parse(event.raw.string(at: "lastTimestamp"))
            ?? KubeDate.parse(event.raw.string(at: "series.lastObservedTime"))
            ?? KubeDate.parse(event.raw.string(at: "eventTime"))
            ?? KubeDate.parse(event.raw.string(at: "firstTimestamp"))
            ?? event.creationTimestamp
    }

    nonisolated static func involvedDescription(_ event: KubeObject) -> String {
        let kind = event.raw.string(at: "involvedObject.kind") ?? ""
        let name = event.raw.string(at: "involvedObject.name") ?? ""
        let namespace = event.raw.string(at: "involvedObject.namespace") ?? event.namespace
        let subject = kind.isEmpty ? name : (name.isEmpty ? kind : "\(kind)/\(name)")
        guard let namespace, !namespace.isEmpty else { return subject }
        return "\(namespace) · \(subject)"
    }

    /// Warnings are orange, except the reasons that mean something is already
    /// broken rather than merely unhappy.
    nonisolated static func tint(for event: KubeObject) -> Color {
        guard event.raw.string(at: "type") == "Warning" else { return .secondary }
        let reason = event.raw.string(at: "reason") ?? ""
        let severe = ["Failed", "BackOff", "Error", "Unhealthy", "Evicted", "OOM"]
        return severe.contains(where: { reason.localizedCaseInsensitiveContains($0) }) ? .red : .orange
    }
}

// MARK: - Fetching

private enum WorkloadFetch {
    struct Outcome: Sendable {
        var key: String
        var objects: [KubeObject] = []
        var failure: String?
    }

    static let pageSize = 500

    /// Never throws: a kind the user cannot list becomes a failed outcome so the
    /// rest of the page still renders.
    static func load(
        key: String, client: KubeClient, resource: APIResource, namespaces: [String]?, cap: Int
    ) async -> Outcome {
        do {
            let objects = try await objects(
                client: client, resource: resource, namespaces: namespaces, cap: cap
            )
            return Outcome(key: key, objects: objects)
        } catch is CancellationError {
            return Outcome(key: key, failure: nil)
        } catch {
            return Outcome(key: key, failure: await ClusterConnection.describe(error))
        }
    }

    private static func objects(
        client: KubeClient, resource: APIResource, namespaces: [String]?, cap: Int
    ) async throws -> [KubeObject] {
        let scope = resource.namespaced ? namespaces : nil
        if let scope, scope.count == 1 {
            return try await page(client: client, resource: resource, namespace: scope[0], cap: cap)
        }
        do {
            let all = try await page(client: client, resource: resource, namespace: nil, cap: cap)
            guard let scope else { return all }
            let allowed = Set(scope)
            return all.filter { allowed.contains($0.namespace ?? "") }
        } catch let error as KubeStatusError where error.isForbidden {
            // No cluster-wide list permission; gather the selected namespaces instead.
            guard let scope, !scope.isEmpty else { throw error }
            var merged: [KubeObject] = []
            for namespace in scope {
                merged += try await page(client: client, resource: resource, namespace: namespace, cap: cap)
            }
            return merged
        }
    }

    private static func page(
        client: KubeClient, resource: APIResource, namespace: String?, cap: Int
    ) async throws -> [KubeObject] {
        var result: [KubeObject] = []
        var continueToken: String?
        // A server that keeps handing back a continue token — or one that
        // returns empty pages — must not spin this loop forever.
        let maxPages = max(1, cap / pageSize + 1)
        var pages = 0
        repeat {
            var query = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let continueToken { query.append(URLQueryItem(name: "continue", value: continueToken)) }
            let list = try await client.get(path: resource.listPath(namespace: namespace), query: query)
            for item in list.array(at: "items") {
                result.append(stamped(item, resource: resource))
            }
            continueToken = list.string(at: "metadata.continue")
            pages += 1
            if pages >= maxPages || result.count >= cap { break }
            try Task.checkCancellation()
        } while continueToken?.isEmpty == false
        return result
    }

    /// List items omit `apiVersion`/`kind`, which `KubeObject.health` switches on,
    /// so the enclosing list's identity is written back onto every item.
    private static func stamped(_ item: JSONValue, resource: APIResource) -> KubeObject {
        guard let existing = item.objectValue, existing["kind"] == nil else { return KubeObject(item) }
        var rebuilt = JSONObject()
        rebuilt["apiVersion"] = .string(resource.groupVersion)
        rebuilt["kind"] = .string(resource.kind)
        for (key, value) in existing.pairs { rebuilt[key] = value }
        return KubeObject(.object(rebuilt))
    }
}

// MARK: - Ring

private struct HealthRing: View {
    let slices: [WorkloadOverviewModel.HealthSlice]
    let total: Int
    var lineWidth: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let radius = (min(size.width, size.height) - lineWidth) / 2
            guard radius > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            var track = Path()
            track.addArc(
                center: center, radius: radius,
                startAngle: .zero, endAngle: .degrees(360), clockwise: false
            )
            context.stroke(
                track,
                with: .color(Color.secondary.opacity(0.16)),
                style: StrokeStyle(lineWidth: lineWidth)
            )

            guard total > 0 else { return }
            // A separator only reads as one when there is more than a single arc.
            let gap = slices.count > 1 ? 2.0 : 0.0
            var start = -90.0
            for slice in slices {
                let sweep = 360 * Double(slice.count) / Double(total)
                let begin = start + gap / 2
                let end = max(begin + 0.5, start + sweep - gap / 2)
                var arc = Path()
                arc.addArc(
                    center: center, radius: radius,
                    startAngle: .degrees(begin), endAngle: .degrees(end), clockwise: false
                )
                context.stroke(
                    arc,
                    with: .color(slice.health.color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
                start += sweep
            }
        }
        .accessibilityLabel(Text(summary))
    }

    private var summary: String {
        guard total > 0 else { return "empty" }
        return slices.map { "\($0.count) \($0.health.label)" }.joined(separator: ", ")
    }
}
