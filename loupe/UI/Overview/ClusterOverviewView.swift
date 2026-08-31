import Foundation
import SwiftUI

/// The cluster landing page: identity, capacity tiles, node health and the
/// warnings the cluster is currently emitting.
struct ClusterOverviewView: View {
    let connection: ClusterConnection
    @Binding var inspection: InspectionTarget?

    @State private var model = ClusterOverviewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let message = model.errorMessage {
                    Banner(message: message, tint: .red) { model.errorMessage = nil }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if model.hasLoaded {
                    tiles
                    nodesCard
                    warningsCard
                    footer
                } else if model.errorMessage == nil {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading cluster state…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(model.isLoading)
            }
        }
        .task(id: connection.id) {
            await refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await refreshAll()
            }
        }
    }

    private func refreshAll() async {
        async let metrics: Void = connection.refreshMetrics()
        await model.load(connection: connection)
        await metrics
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.name)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(connection.target.cluster.server)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Chip(
                    text: connection.serverVersion ?? "version unknown",
                    color: .accentColor,
                    systemImage: "shippingbox"
                )
                Chip(
                    text: connection.metricsSource.label,
                    color: metricsChipColor,
                    systemImage: "waveform.path.ecg"
                )
                .help(connection.metricsError
                      ?? (connection.metricsAvailable
                          ? "CPU and memory usage is read from \(connection.metricsSource.label)."
                          : "No usage source. Install metrics-server, or point Loupe at Prometheus "
                              + "in Settings › Metrics."))
                Button {
                    Task { await connection.reconnect() }
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
            }

            HStack(spacing: 5) {
                Image(systemName: "doc.text").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(connection.target.sourceFile?.path ?? "kubeconfig source unknown")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let contextNamespace = connection.target.namespace, !contextNamespace.isEmpty {
                    Text("·").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Text("context namespace \(contextNamespace)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Keyed by position: two probes can report the same message.
            ForEach(Array(connection.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Amber for a source that is selected but not answering: silently showing
    /// it as "off" would hide a misconfigured endpoint.
    private var metricsChipColor: Color {
        if connection.metricsError != nil { return .orange }
        return connection.metricsAvailable ? .green : .secondary
    }

    // MARK: Tiles

    private var tiles: some View {
        let totals = self.totals
        let cpuValue = connection.metricsAvailable ? totals.cpuUsed : totals.cpuRequested
        let memoryValue = connection.metricsAvailable ? totals.memoryUsed : totals.memoryRequested
        let fallbackCaption = "requests (no usage source)"

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            StatTile(
                title: "Nodes",
                value: "\(totals.nodesReady)/\(totals.nodesTotal)",
                caption: totals.nodesTotal == totals.nodesReady ? "all ready" : "ready",
                systemImage: "server.rack",
                tint: totals.nodesReady < totals.nodesTotal ? .orange : .blue,
                progress: (Double(totals.nodesReady), Double(totals.nodesTotal)),
                progressWarnsWhenFull: false
            )
            StatTile(
                title: "Pods",
                value: "\(totals.podsRunning)/\(totals.podCapacity)",
                caption: totals.podsTruncated ? "showing first \(totals.podsTotal)" : "\(totals.podsTotal) total",
                systemImage: "cube",
                tint: .teal,
                progress: (Double(totals.podsRunning), Double(totals.podCapacity))
            )
            StatTile(
                title: "CPU",
                value: Quantity.formatCPU(cpuValue),
                caption: connection.metricsAvailable
                    ? "of \(Quantity.formatCPU(totals.cpuAllocatable)) allocatable"
                    : fallbackCaption,
                systemImage: "cpu",
                tint: .purple,
                progress: (cpuValue, totals.cpuAllocatable)
            )
            .help(connection.metricsAvailable
                  ? "Live usage across all nodes, from \(connection.metricsSource.label)"
                  : "Sum of pod CPU requests — no usage source. "
                      + "Install metrics-server, or point Loupe at Prometheus in Settings › Metrics.")
            StatTile(
                title: "Memory",
                value: Quantity.formatBytes(memoryValue),
                caption: connection.metricsAvailable
                    ? "of \(Quantity.formatBytes(totals.memoryAllocatable)) allocatable"
                    : fallbackCaption,
                systemImage: "memorychip",
                tint: .indigo,
                progress: (memoryValue, totals.memoryAllocatable)
            )
            .help(connection.metricsAvailable
                  ? "Live usage across all nodes, from \(connection.metricsSource.label)"
                  : "Sum of pod memory requests — no usage source. "
                      + "Install metrics-server, or point Loupe at Prometheus in Settings › Metrics.")
            StatTile(
                title: "Namespaces",
                value: "\(connection.namespaces.count)",
                caption: connection.selectedNamespaces.isEmpty
                    ? "no filter"
                    : "\(connection.selectedNamespaces.count) selected",
                systemImage: "square.stack.3d.up",
                tint: .cyan
            )
            StatTile(
                title: "Warnings",
                value: "\(totals.warningsLastHour)",
                caption: "last hour",
                systemImage: "exclamationmark.triangle",
                tint: totals.warningsLastHour > 0 ? .orange : .green
            )
        }
    }

    // MARK: Nodes

    private var nodesCard: some View {
        Card(title: "Nodes", systemImage: "server.rack", trailing: "\(model.nodes.count)") {
            if model.nodes.isEmpty {
                Text("No nodes are visible to this user.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(sortedNodes.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Divider().opacity(0.35) }
                        NodeRow(
                            node: node,
                            metrics: connection.nodeMetrics[node.name],
                            cpuAllocatable: Self.millicores(node.raw.value(at: "status.allocatable.cpu")),
                            memoryAllocatable: Self.byteCount(node.raw.value(at: "status.allocatable.memory")),
                            showsMetrics: connection.metricsAvailable
                        ) {
                            inspection = InspectionTarget(
                                object: node,
                                resource: connection.catalog.resource(kind: "Node")
                            )
                        }
                    }
                }
            }
        }
    }

    private var sortedNodes: [KubeObject] {
        model.nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Warnings

    private var warningsCard: some View {
        Card(title: "Recent warnings", systemImage: "bell", trailing: model.eventsTrailing) {
            if model.events.isEmpty {
                Text("No warning events reported.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(model.recentWarnings.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().opacity(0.35) }
                        EventRow(event: event) {
                            Task {
                                if let target = await model.inspectionTarget(for: event, connection: connection) {
                                    inspection = target
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            }
            Text(model.lastUpdated.map { "Updated \(Age.short(since: $0)) ago" } ?? "Never updated")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Aggregation

    private struct Totals {
        var nodesReady = 0
        var nodesTotal = 0
        var podsRunning = 0
        var podsTotal = 0
        var podsTruncated = false
        var podCapacity = 0
        var cpuAllocatable = 0.0
        var memoryAllocatable = 0.0
        var cpuUsed = 0.0
        var memoryUsed = 0.0
        var cpuRequested = 0.0
        var memoryRequested = 0.0
        var warningsLastHour = 0
    }

    private var totals: Totals {
        var totals = Totals()
        totals.nodesTotal = model.nodes.count
        for node in model.nodes {
            if node.condition("Ready")?.isTrue == true { totals.nodesReady += 1 }
            totals.podCapacity += Self.integer(node.raw.value(at: "status.allocatable.pods"))
            totals.cpuAllocatable += Self.millicores(node.raw.value(at: "status.allocatable.cpu"))
            totals.memoryAllocatable += Self.byteCount(node.raw.value(at: "status.allocatable.memory"))
            if let metrics = connection.nodeMetrics[node.name] {
                totals.cpuUsed += metrics.cpuMillicores
                totals.memoryUsed += metrics.memoryBytes
            }
        }

        totals.podsTotal = model.pods.count
        totals.podsTruncated = model.podsTruncated
        for pod in model.pods {
            let phase = pod.raw.string(at: "status.phase") ?? ""
            if phase == "Running" { totals.podsRunning += 1 }
            // Finished pods hold no allocation, so they must not count as requests.
            guard phase != "Succeeded", phase != "Failed" else { continue }
            for container in pod.raw.array(at: "spec.containers") {
                totals.cpuRequested += Self.millicores(container.value(at: "resources.requests.cpu"))
                totals.memoryRequested += Self.byteCount(container.value(at: "resources.requests.memory"))
            }
        }

        let cutoff = Date().addingTimeInterval(-3600)
        totals.warningsLastHour = model.events.filter {
            (ClusterOverviewModel.timestamp(of: $0) ?? .distantPast) > cutoff
        }.count

        // Sums can still run away even when every term was sane.
        totals.cpuAllocatable = Self.finite(totals.cpuAllocatable)
        totals.memoryAllocatable = Self.finite(totals.memoryAllocatable)
        totals.cpuUsed = Self.finite(totals.cpuUsed)
        totals.memoryUsed = Self.finite(totals.memoryUsed)
        totals.cpuRequested = Self.finite(totals.cpuRequested)
        totals.memoryRequested = Self.finite(totals.memoryRequested)
        return totals
    }

    /// Quantities arrive as strings but tolerate a bare JSON number.
    private static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue { return string }
        if let int = value.intValue { return String(int) }
        if let double = value.doubleValue { return String(double) }
        return nil
    }

    /// `Quantity.formatBytes` finishes with `Int(value.rounded())`, which traps
    /// on a non-finite or astronomically large `Double` — and `Quantity.bytes`
    /// hands one back for quantity strings like `inf` or `1e400`, which a
    /// broken node or CRI really can report. Everything fed to a formatter or
    /// a bar goes through here first.
    private static func finite(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, 1e24)
    }

    private static func millicores(_ value: JSONValue?) -> Double {
        finite(Quantity.millicores(text(value)))
    }

    private static func byteCount(_ value: JSONValue?) -> Double {
        finite(Quantity.bytes(text(value)))
    }

    private static func integer(_ value: JSONValue?) -> Int {
        guard let text = text(value) else { return 0 }
        if let exact = Int(text) { return exact }
        let parsed = Quantity.bytes(text)
        guard parsed.isFinite, parsed >= 0, parsed < 1e12 else { return 0 }
        return Int(parsed)
    }

    // MARK: Building blocks

    private struct Card<Content: View>: View {
        let title: String
        var systemImage: String
        var trailing: String?
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let trailing {
                        Text(trailing).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                content
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private struct NodeRow: View {
        let node: KubeObject
        let metrics: NodeMetrics?
        let cpuAllocatable: Double
        let memoryAllocatable: Double
        let showsMetrics: Bool
        let activate: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: activate) {
                HStack(spacing: 10) {
                    HealthDot(health: node.health)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(node.raw.string(at: "status.nodeInfo.kubeletVersion") ?? "—")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 140, alignment: .leading)

                    HStack(spacing: 3) {
                        if roles.isEmpty {
                            Text("—").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        } else {
                            ForEach(roles.prefix(2), id: \.self) { Chip(text: $0, color: .blue) }
                            if roles.count > 2 {
                                Text("+\(roles.count - 2)").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if node.raw.bool(at: "spec.unschedulable") == true {
                            Chip(text: "cordoned", color: .orange, systemImage: "hand.raised")
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                    .clipped()

                    Spacer(minLength: 8)

                    usage("CPU", value: metrics?.cpuMillicores, total: cpuAllocatable, format: Quantity.formatCPU)
                    usage("MEM", value: metrics?.memoryBytes, total: memoryAllocatable, format: Quantity.formatBytes)

                    AgeText(date: node.creationTimestamp)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    hovering ? Color.secondary.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }

        private func usage(
            _ title: String,
            value: Double?,
            total: Double,
            format: (Double) -> String
        ) -> some View {
            // `nodeMetrics` is parsed by ClusterConnection without a sanity
            // clamp, so guard it the same way the aggregates are.
            let used = value.map { ClusterOverviewView.finite($0) }
            return VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(label(value: used, total: total, format: format))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                UsageBar(value: used ?? 0, total: total)
            }
            .frame(width: 132)
            .opacity(showsMetrics ? 1 : 0.55)
        }

        private func label(value: Double?, total: Double, format: (Double) -> String) -> String {
            let capacity = total > 0 ? format(total) : "—"
            guard let value else { return "— / \(capacity)" }
            return "\(format(value)) / \(capacity)"
        }

        private var roles: [String] {
            let prefix = "node-role.kubernetes.io/"
            var found: [String] = []
            for (key, value) in node.labels {
                let role: String
                if key.hasPrefix(prefix) {
                    let suffix = String(key.dropFirst(prefix.count))
                    role = suffix.isEmpty ? value : suffix
                } else if key == "kubernetes.io/role" {
                    role = value
                } else {
                    continue
                }
                // `node-role…/master` and `kubernetes.io/role: master` name the
                // same role, and a repeat would collide in the `id: \.self`
                // ForEach below.
                if !role.isEmpty, !found.contains(role) { found.append(role) }
            }
            return found.sorted()
        }
    }

    private struct EventRow: View {
        let event: KubeObject
        let activate: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: activate) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(subject)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Chip(text: event.raw.string(at: "reason") ?? "—", color: .orange)
                            if count > 1 {
                                Text("×\(count)").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Text(message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    AgeText(date: ClusterOverviewModel.timestamp(of: event))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    hovering ? Color.secondary.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }

        private var subject: String {
            let kind = event.raw.string(at: "involvedObject.kind") ?? "Object"
            let name = event.raw.string(at: "involvedObject.name") ?? "—"
            if let namespace = event.raw.string(at: "involvedObject.namespace"), !namespace.isEmpty {
                return "\(kind) \(namespace)/\(name)"
            }
            return "\(kind) \(name)"
        }

        private var message: String {
            event.raw.string(at: "message") ?? event.raw.string(at: "note") ?? "—"
        }

        private var count: Int {
            event.raw.int(at: "count") ?? event.raw.int(at: "series.count") ?? 1
        }
    }
}

// MARK: - Model

@MainActor
@Observable
private final class ClusterOverviewModel {
    private(set) var nodes: [KubeObject] = []
    private(set) var pods: [KubeObject] = []
    private(set) var events: [KubeObject] = []
    private(set) var podsTruncated = false
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var lastUpdated: Date?
    var errorMessage: String?

    private static let podLimit = 3000
    private static let eventLimit = 200

    func load(connection: ClusterConnection) async {
        guard let client = connection.client else {
            errorMessage = "Not connected to \(connection.name)."
            return
        }
        guard !isLoading else { return }
        isLoading = true

        async let nodeList = client.get(path: "/api/v1/nodes")
        async let podList = client.get(
            path: "/api/v1/pods",
            query: [URLQueryItem(name: "limit", value: String(Self.podLimit))]
        )
        async let eventList = client.get(
            path: "/api/v1/events",
            query: [
                URLQueryItem(name: "fieldSelector", value: "type=Warning"),
                URLQueryItem(name: "limit", value: String(Self.eventLimit)),
            ]
        )

        // Each fetch is reported on its own so one denied endpoint does not
        // wipe the panels that did load.
        var failures: [String] = []
        do {
            nodes = Self.items(try await nodeList, kind: "Node")
        } catch {
            failures.append("Nodes: \(ClusterConnection.describe(error))")
        }
        do {
            let list = try await podList
            pods = Self.items(list, kind: "Pod")
            podsTruncated = list.string(at: "metadata.continue")?.isEmpty == false
        } catch {
            failures.append("Pods: \(ClusterConnection.describe(error))")
        }
        do {
            events = Self.items(try await eventList, kind: "Event")
        } catch {
            failures.append("Events: \(ClusterConnection.describe(error))")
        }

        // A cancelled refresh means the view went away or the cluster changed;
        // the "cancelled" URLErrors it produces are not cluster problems, so
        // whatever was already on screen is left exactly as it was.
        if !Task.isCancelled {
            errorMessage = failures.isEmpty ? nil : failures.joined(separator: "  ·  ")
            lastUpdated = Date()
            hasLoaded = true
        }
        isLoading = false
    }

    var recentWarnings: [KubeObject] {
        events
            .sorted { (Self.timestamp(of: $0) ?? .distantPast) > (Self.timestamp(of: $1) ?? .distantPast) }
            .prefix(12)
            .map { $0 }
    }

    var eventsTrailing: String? {
        guard !events.isEmpty else { return nil }
        return events.count > 12 ? "12 of \(events.count)" : "\(events.count)"
    }

    /// Resolves the object an event points at, so the row can open the inspector.
    func inspectionTarget(for event: KubeObject, connection: ClusterConnection) async -> InspectionTarget? {
        guard let client = connection.client,
              let kind = event.raw.string(at: "involvedObject.kind"), !kind.isEmpty,
              let name = event.raw.string(at: "involvedObject.name"), !name.isEmpty
        else { return nil }

        let apiVersion = event.raw.string(at: "involvedObject.apiVersion") ?? ""
        let resource = (apiVersion.isEmpty ? nil : connection.catalog.resource(apiVersion: apiVersion, kind: kind))
            ?? connection.catalog.resource(kind: kind)
        guard let resource else { return nil }

        let namespace = event.raw.string(at: "involvedObject.namespace")
        do {
            let raw = try await client.get(path: resource.itemPath(namespace: namespace, name: name))
            return InspectionTarget(object: KubeObject(raw), resource: resource)
        } catch {
            errorMessage = "Could not open \(kind) \(name): \(ClusterConnection.describe(error))"
            return nil
        }
    }

    /// List items omit `kind`/`apiVersion`; restoring them keeps health rules
    /// and the inspector working on the objects handed out here.
    private static func items(_ list: JSONValue, kind: String) -> [KubeObject] {
        list.array(at: "items").map { item in
            guard let object = item.objectValue else { return KubeObject(item) }
            var decorated = JSONObject([("apiVersion", .string("v1")), ("kind", .string(kind))])
            for (key, value) in object.pairs { decorated[key] = value }
            return KubeObject(.object(decorated))
        }
    }

    static func timestamp(of event: KubeObject) -> Date? {
        KubeDate.parse(event.raw.string(at: "lastTimestamp"))
            ?? KubeDate.parse(event.raw.string(at: "eventTime"))
            ?? event.creationTimestamp
    }
}
