import SwiftUI

/// Browses one resource type: toolbar, live table, and the actions that apply.
struct ResourceBrowserView: View {
    let connection: ClusterConnection
    let resource: APIResource
    @Binding var inspection: InspectionTarget?

    @Environment(AppModel.self) private var app

    @State private var model: ResourceListModel
    @State private var runner = ActionRunner()
    @State private var selection: String?
    @State private var pendingDeletion: ResourceRow?
    @State private var scaleTarget: ResourceRow?
    @State private var editTarget: ResourceRow?
    @State private var forwardTarget: ResourceRow?
    @State private var pendingDrain: ResourceRow?

    init(connection: ClusterConnection, resource: APIResource, inspection: Binding<InspectionTarget?>) {
        self.connection = connection
        self.resource = resource
        self._inspection = inspection
        self._model = State(wrappedValue: ResourceListModel(resource: resource, connection: connection))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let message = runner.errorMessage {
                Banner(message: message, tint: .red) { runner.errorMessage = nil }
            }
            if let message = runner.statusMessage {
                Banner(message: message, tint: .green) { runner.statusMessage = nil }
            }
            if let message = model.errorMessage, !model.rows.isEmpty {
                Banner(message: message, tint: .orange) { model.refresh() }
            }
            content
        }
        .toolbar { toolbarContent }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search \(resource.displayName)")
        .navigationTitle(resource.displayName)
        .task(id: connection.selectedNamespaces) { model.start() }
        .onDisappear { model.stop() }
        // Usage arrives on the connection's own 30-second cycle, not through
        // the watch, so the rows are restamped whenever a snapshot lands.
        .onChange(of: connection.metricsRevision) { _, _ in model.applyUsage() }
        .onChange(of: selection) { _, newValue in
            guard let newValue, let row = model.rows.first(where: { $0.id == newValue }) else { return }
            inspection = InspectionTarget(object: row.object, resource: resource)
        }
        .onChange(of: inspection) { _, newValue in
            // Clear the selection when the inspector closes, so clicking the
            // same row again reopens it.
            if newValue == nil { selection = nil }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.object.name ?? "")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let row = pendingDeletion, let client = connection.client else { return }
                pendingDeletion = nil
                runner.run("Deleted \(row.object.name)") {
                    try await ResourceActions.delete(client: client, resource: resource, object: row.object)
                    return "Deleted \(row.object.name)"
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This permanently removes the \(resource.kind) from the cluster.")
        }
        .sheet(item: $scaleTarget) { row in
            ScaleSheet(row: row) { replicas in
                guard let client = connection.client else { return }
                runner.run("Scaled \(row.object.name)") {
                    try await ResourceActions.scale(
                        client: client, resource: resource, object: row.object, replicas: replicas
                    )
                    return "Scaled \(row.object.name) to \(replicas)"
                }
            }
        }
        .confirmationDialog(
            "Drain \(pendingDrain?.object.name ?? "")?",
            isPresented: Binding(get: { pendingDrain != nil }, set: { if !$0 { pendingDrain = nil } }),
            titleVisibility: .visible
        ) {
            Button("Cordon and Drain", role: .destructive) {
                guard let row = pendingDrain, let client = connection.client else { return }
                pendingDrain = nil
                runner.run("Draining \(row.object.name)") {
                    let summary = try await ResourceActions.drain(
                        client: client, resource: resource, object: row.object
                    )
                    if !summary.failures.isEmpty {
                        throw ActionError.message(
                            "Drain incomplete — \(summary.describes). "
                                + summary.failures.prefix(3).joined(separator: "; ")
                        )
                    }
                    return "Drained \(row.object.name): \(summary.describes)"
                }
            }
            Button("Cancel", role: .cancel) { pendingDrain = nil }
        } message: {
            Text("The node is cordoned and its pods are evicted. DaemonSet, static and "
                 + "unmanaged pods are left in place.")
        }
        .sheet(item: $forwardTarget) { row in
            PortForwardSheet(pod: row.object) { remotePort, localPort, label in
                guard let client = connection.client, let namespace = row.object.namespace else { return }
                app.portForwards.start(
                    client: client,
                    contextName: connection.target.contextName,
                    namespace: namespace,
                    podName: row.object.name,
                    remotePort: remotePort,
                    localPort: localPort,
                    label: label
                )
                runner.statusMessage = "Forwarding \(row.object.name):\(remotePort)"
            }
        }
        .sheet(item: $editTarget) { row in
            YAMLEditorSheet(object: row.object) { yaml in
                guard let client = connection.client else { return }
                runner.run("Applied changes") {
                    _ = try await ResourceActions.replace(
                        client: client, resource: resource, object: row.object, yaml: yaml
                    )
                    return "Applied changes to \(row.object.name)"
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.rows.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading \(resource.displayName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.rows.isEmpty {
            EmptyStateView(
                title: "Could not load \(resource.displayName)",
                message: error,
                systemImage: "exclamationmark.triangle",
                action: ("Retry", { model.refresh() })
            )
        } else if model.rows.isEmpty {
            EmptyStateView(
                title: "No \(resource.displayName.lowercased())",
                message: scopeDescription,
                systemImage: NavigationCatalog.icon(for: resource)
            )
        } else {
            table
        }
    }

    private var table: some View {
        @Bindable var model = model
        let columns = model.displayColumns
        return VStack(spacing: 0) {
            ResourceTableView(
                columns: columns,
                rows: model.displayedRows(columns: columns),
                selection: $selection,
                sortColumn: $model.sortColumnID,
                sortAscending: $model.sortAscending,
                showsHealth: model.reportsHealth,
                onActivate: { row in
                    inspection = InspectionTarget(object: row.object, resource: resource)
                },
                rowMenu: { row in AnyView(menu(for: row)) }
            )
            statusBar(columns: columns)
        }
    }

    private func statusBar(columns: [DisplayColumn]) -> some View {
        HStack(spacing: 10) {
            Text("\(model.displayedRows(columns: columns).count) of \(model.rows.count)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            ForEach(healthChips, id: \.0) { health, count in
                HStack(spacing: 3) {
                    HealthDot(health: health, size: 6)
                    Text("\(count)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .help(health.label)
            }
            if model.truncated {
                Chip(text: "truncated", color: .orange, systemImage: "scissors")
            }
            Spacer()
            if model.isWatching {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("live").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if let updated = model.lastUpdated {
                Text("updated \(Age.short(since: updated)) ago")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var healthChips: [(ResourceHealth, Int)] {
        // Kinds with no status have nothing to summarise: every row would land
        // in the same grey "Unknown" bucket.
        guard model.reportsHealth else { return [] }
        return model.healthSummary
            .filter { $0.key != .ok && $0.value > 0 }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value) }
    }

    private var scopeDescription: String? {
        guard resource.namespaced else { return nil }
        guard let namespaces = connection.effectiveNamespaces else { return "Searched every namespace." }
        return "Searched \(namespaces.joined(separator: ", "))."
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("Show extra columns", isOn: Binding(
                    get: { model.showWideColumns }, set: { model.showWideColumns = $0 }
                ))
                Divider()
                Button("Clear sort") { model.sortColumnID = nil }
                    .disabled(model.sortColumnID == nil)
                Divider()
                if resource.kind == "Pod", resource.group.isEmpty, !connection.metricsAvailable {
                    Text("CPU and memory need a metrics source — choose one in Settings › Metrics.")
                    Divider()
                }
                Text(resource.groupVersion)
                Text(resource.namespaced ? "Namespaced" : "Cluster-scoped")
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.isLoading)
        }
    }

    @ViewBuilder
    private func menu(for row: ResourceRow) -> some View {
        Button("Show Details") { inspection = InspectionTarget(object: row.object, resource: resource) }
        if resource.kind == "Pod" || WorkloadPods.kinds.contains(resource.kind) {
            Button(resource.kind == "Pod" ? "View Logs" : "View Logs (all pods)") {
                inspection = InspectionTarget(object: row.object, resource: resource, initialTab: .logs)
            }
        }
        if resource.kind == "Pod" {
            Button("Open Shell") {
                inspection = InspectionTarget(object: row.object, resource: resource, initialTab: .shell)
            }
            Button("Forward Port…") { forwardTarget = row }
        }
        Divider()
        Button("Copy Name") { ResourceActions.copyToPasteboard(row.object.name) }
        Button("Copy YAML") { ResourceActions.copyToPasteboard(row.object.presentableYAML) }
        Divider()
        if resource.isEditable {
            Button("Edit YAML…") { editTarget = row }
            if resource.subresources.contains("scale") {
                Button("Scale…") { scaleTarget = row }
            }
            if resource.group == "apps",
               ["Deployment", "StatefulSet", "DaemonSet"].contains(resource.kind) {
                Button("Restart Rollout") {
                    guard let client = connection.client else { return }
                    runner.run("Restarted \(row.object.name)") {
                        try await ResourceActions.restart(
                            client: client, resource: resource, object: row.object
                        )
                        return "Restarted \(row.object.name)"
                    }
                }
            }
            if resource.kind == "CronJob", resource.group == "batch" {
                let suspended = row.object.raw.bool(at: "spec.suspend") ?? false
                Button(suspended ? "Resume" : "Suspend") {
                    guard let client = connection.client else { return }
                    runner.run("Updated \(row.object.name)") {
                        try await ResourceActions.setSuspended(
                            client: client, resource: resource, object: row.object, suspended: !suspended
                        )
                        return "\(suspended ? "Resumed" : "Suspended") \(row.object.name)"
                    }
                }
                Button("Trigger Now") {
                    guard let client = connection.client else { return }
                    runner.run("Triggered \(row.object.name)") {
                        let name = try await ResourceActions.triggerCronJob(
                            client: client, object: row.object
                        )
                        return "Created job \(name)"
                    }
                }
            }
            if resource.kind == "Node", resource.group.isEmpty {
                let cordoned = row.object.raw.bool(at: "spec.unschedulable") ?? false
                Button(cordoned ? "Uncordon" : "Cordon") {
                    guard let client = connection.client else { return }
                    runner.run("Updated \(row.object.name)") {
                        try await ResourceActions.setCordoned(
                            client: client, resource: resource, object: row.object, cordoned: !cordoned
                        )
                        return "\(cordoned ? "Uncordoned" : "Cordoned") \(row.object.name)"
                    }
                }
                Button("Drain…", role: .destructive) { pendingDrain = row }
            }
        }
        if resource.isDeletable {
            Divider()
            Button("Delete…", role: .destructive) { pendingDeletion = row }
        }
    }
}

struct Banner: View {
    let message: String
    let tint: Color
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tint == .red ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(message).font(.system(size: 11.5)).textSelection(.enabled)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }
}

struct ScaleSheet: View {
    let row: ResourceRow
    var apply: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var replicas: Int

    init(row: ResourceRow, apply: @escaping (Int) -> Void) {
        self.row = row
        self.apply = apply
        self._replicas = State(wrappedValue: row.object.raw.int(at: "spec.replicas") ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scale \(row.object.name)").font(.headline)
            HStack {
                Stepper(value: $replicas, in: 0...500) {
                    Text("Replicas: \(replicas)").monospacedDigit()
                }
                TextField("", value: $replicas, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onChange(of: replicas) { _, newValue in
                        let clamped = min(max(newValue, 0), 500)
                        if clamped != newValue { replicas = clamped }
                    }
            }
            Text("Currently \(row.object.raw.int(at: "status.readyReplicas") ?? 0) ready of "
                 + "\(row.object.raw.int(at: "spec.replicas") ?? 0) desired.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Scale") {
                    apply(replicas)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
