import SwiftUI

/// The right-hand inspector: a live view of a single object with tabs for its
/// summary, YAML, events and — for pods — logs and a shell.
struct ObjectInspector: View {
    let connection: ClusterConnection
    let target: InspectionTarget
    var onClose: () -> Void

    @Environment(AppModel.self) private var model

    @State private var tab: InspectorTab
    @State private var object: KubeObject
    @State private var runner = ActionRunner()
    @State private var isEditing = false
    @State private var pendingDeletion = false
    @State private var isForwarding = false

    init(connection: ClusterConnection, target: InspectionTarget, onClose: @escaping () -> Void) {
        self.connection = connection
        self.target = target
        self.onClose = onClose
        self._tab = State(wrappedValue: target.initialTab)
        self._object = State(wrappedValue: target.object)
    }

    private var resource: APIResource? {
        target.resource ?? connection.catalog.resource(apiVersion: object.apiVersion, kind: object.kind)
    }

    /// Logs are offered for a pod and for any controller whose pods can be
    /// gathered; a shell only ever makes sense on one pod.
    private var logScope: LogScope? { LogScope.best(for: object) }

    private var availableTabs: [InspectorTab] {
        InspectorTab.allCases.filter { tab in
            switch tab {
            case .logs: return logScope != nil
            case .shell: return object.kind == "Pod"
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(availableTabs) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if let message = runner.errorMessage {
                Banner(message: message, tint: .red) { runner.errorMessage = nil }
            }
            if let message = runner.statusMessage {
                Banner(message: message, tint: .green) { runner.statusMessage = nil }
            }

            Divider()
            content
        }
        .task(id: object.id) { await watchObject() }
        .sheet(isPresented: $isEditing) {
            YAMLEditorSheet(object: object) { yaml in
                guard let client = connection.client, let resource else { return }
                runner.run("Applied changes") {
                    let updated = try await ResourceActions.replace(
                        client: client, resource: resource, object: object, yaml: yaml
                    )
                    object = updated
                    return "Applied changes to \(updated.name)"
                }
            }
        }
        .sheet(isPresented: $isForwarding) {
            PortForwardSheet(pod: object) { remotePort, localPort, label in
                guard let client = connection.client, let namespace = object.namespace else { return }
                model.portForwards.start(
                    client: client,
                    contextName: connection.target.contextName,
                    namespace: namespace,
                    podName: object.name,
                    remotePort: remotePort,
                    localPort: localPort,
                    label: label
                )
                runner.statusMessage = "Forwarding \(object.name):\(remotePort)"
            }
        }
        .confirmationDialog(
            "Delete \(object.name)?", isPresented: $pendingDeletion, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let client = connection.client, let resource else { return }
                runner.run("Deleted") {
                    try await ResourceActions.delete(client: client, resource: resource, object: object)
                    onClose()
                    return nil
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            ScrollView {
                ObjectOverview(connection: connection, object: object, runner: runner)
                    .padding(14)
            }
        case .yaml:
            YAMLDocumentView(text: object.presentableYAML)
        case .events:
            ObjectEventsView(connection: connection, object: object)
        case .logs:
            if let logScope {
                LogsView(connection: connection, scope: logScope)
                    // Identity follows the object, not the watch event that
                    // last refreshed it, so live updates do not restart the
                    // streams and throw away everything already on screen.
                    .id(object.id)
            }
        case .shell:
            PodTerminalView(connection: connection, pod: object)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: NavigationCatalog.iconsByKind[object.kind] ?? "circle.grid.2x2")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(object.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack(spacing: 5) {
                        Text(object.kind).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let namespace = object.namespace {
                            Text("·").foregroundStyle(.tertiary)
                            Text(namespace).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                actionsMenu
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close inspector")
            }
            HStack(spacing: 6) {
                // Kinds with no status — ConfigMaps, RBAC rules — have no
                // health to report, so claiming "Unknown" would be noise.
                if object.health != .unknown {
                    Chip(
                        text: object.health.label,
                        color: object.health.color,
                        systemImage: object.health.symbol
                    )
                }
                Chip(text: object.apiVersion, color: .secondary)
                if let created = object.creationTimestamp {
                    Chip(text: Age.short(since: created), color: .secondary, systemImage: "clock")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var actionsMenu: some View {
        Menu {
            Button("Copy Name") { ResourceActions.copyToPasteboard(object.name) }
            Button("Copy YAML") { ResourceActions.copyToPasteboard(object.presentableYAML) }
            if object.kind == "Pod" {
                Divider()
                Button("Forward Port…") { isForwarding = true }
            }
            if let resource {
                Divider()
                if resource.isEditable {
                    Button("Edit YAML…") { isEditing = true }
                }
                if resource.group == "apps", resource.isEditable,
                   ["Deployment", "StatefulSet", "DaemonSet"].contains(object.kind) {
                    Button("Restart Rollout") {
                        guard let client = connection.client else { return }
                        runner.run("Restarted") {
                            try await ResourceActions.restart(
                                client: client, resource: resource, object: object
                            )
                            return "Restart triggered"
                        }
                    }
                }
                if object.kind == "CronJob", resource.group == "batch" {
                    Button("Run Now") { triggerCronJob() }
                    if resource.isEditable {
                        let suspended = object.raw.bool(at: "spec.suspend") ?? false
                        Button(suspended ? "Resume Schedule" : "Suspend Schedule") {
                            guard let client = connection.client else { return }
                            runner.run("Updated") {
                                try await ResourceActions.setSuspended(
                                    client: client, resource: resource,
                                    object: object, suspended: !suspended
                                )
                                return suspended ? "Schedule resumed" : "Schedule suspended"
                            }
                        }
                    }
                }
                if resource.isDeletable {
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDeletion = true }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func triggerCronJob() {
        guard let client = connection.client else { return }
        runner.run("Triggered") {
            let name = try await ResourceActions.triggerCronJob(client: client, object: object)
            return "Created job \(name)"
        }
    }

    /// Keeps the inspector in sync by watching just this object. Cancellation
    /// is owned by `.task(id:)`, so no task handle is kept.
    ///
    /// The watch deliberately carries no `resourceVersion`: an object's own
    /// version is frequently older than the API server's history window, and
    /// starting from "now" costs one replayed ADDED event instead of an
    /// immediate `Expired` error.
    private func watchObject() async {
        guard let client = connection.client, let resource, resource.isWatchable else { return }
        let namespace = object.namespace
        let query = [
            URLQueryItem(name: "watch", value: "true"),
            URLQueryItem(name: "fieldSelector", value: "metadata.name=\(object.name)"),
            URLQueryItem(name: "allowWatchBookmarks", value: "true"),
        ]
        let request = KubeRequest.get(resource.listPath(namespace: namespace), query: query)
        var backoff: Duration = .seconds(1)

        while !Task.isCancelled {
            do {
                for try await line in client.lines(request) {
                    guard let event = WatchEvent.decode(line) else { continue }
                    switch event.type {
                    case .added, .modified:
                        object = KubeObject(event.payload)
                        backoff = .seconds(1)
                    case .deleted:
                        object = KubeObject(event.payload)
                        return
                    case .error:
                        break
                    case .bookmark:
                        continue
                    }
                }
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }
}
