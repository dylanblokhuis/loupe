import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// Remembered per context, and persisted, so switching clusters — or
    /// relaunching — returns you where you were.
    @AppStorage("loupe.selections") private var storedSelections = ""
    @State private var inspection: InspectionTarget?

    private var selections: [String: NavDestination] {
        get {
            var result: [String: NavDestination] = [:]
            for entry in storedSelections.split(separator: "\n") {
                let parts = entry.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, let destination = NavDestination(storageKey: parts[1]) else { continue }
                result[parts[0]] = destination
            }
            return result
        }
        nonmutating set {
            storedSelections = newValue
                .map { "\($0.key)\t\($0.value.storageKey)" }
                .sorted()
                .joined(separator: "\n")
        }
    }

    private var selection: Binding<NavDestination?> {
        Binding(
            get: {
                guard let context = model.activeContextName else { return nil }
                return selections[context]
            },
            set: { newValue in
                guard let context = model.activeContextName else { return }
                var updated = selections
                updated[context] = newValue
                selections = updated
                inspection = nil
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .inspector(isPresented: Binding(get: { inspection != nil }, set: { if !$0 { inspection = nil } })) {
            if let inspection, let connection = model.activeConnection {
                ObjectInspector(connection: connection, target: inspection) { self.inspection = nil }
                    // Without a distinct identity per object SwiftUI keeps the
                    // first inspector's @State, so selecting another row would
                    // leave Delete and Edit pointed at the previous object.
                    .id(inspection.id)
                    .inspectorColumnWidth(min: 380, ideal: 520, max: 900)
            }
        }
        .onChange(of: model.activeContextName) { _, newValue in
            inspection = nil
            guard let newValue, selections[newValue] == nil else { return }
            var updated = selections
            updated[newValue] = .clusterOverview
            selections = updated
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let connection = model.activeConnection {
            ClusterDetailView(
                connection: connection,
                destination: selection.wrappedValue,
                inspection: $inspection
            )
            .id(connection.id)
        } else {
            WelcomeView()
        }
    }
}

/// What the inspector is currently showing.
struct InspectionTarget: Identifiable, Equatable {
    var object: KubeObject
    var resource: APIResource?
    /// Opens straight to a specific tab, e.g. logs from a pod's context menu.
    var initialTab: InspectorTab = .overview

    /// Includes the tab so asking for the same pod's logs after its overview
    /// re-seeds the inspector on the tab that was requested.
    var id: String { "\(object.id)|\(initialTab.rawValue)" }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case yaml = "YAML"
    case events = "Events"
    case logs = "Logs"
    case shell = "Shell"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "info.circle"
        case .yaml: return "doc.text"
        case .events: return "bell"
        case .logs: return "text.alignleft"
        case .shell: return "terminal"
        }
    }
}

/// Routes the selected sidebar entry to the right browser or overview.
struct ClusterDetailView: View {
    let connection: ClusterConnection
    let destination: NavDestination?
    @Binding var inspection: InspectionTarget?

    var body: some View {
        Group {
            switch connection.state {
            case .idle, .connecting:
                connectingView
            case .failed(let message):
                EmptyStateView(
                    title: "Could not connect to \(connection.name)",
                    message: message,
                    systemImage: "exclamationmark.triangle",
                    action: ("Retry", { Task { await connection.reconnect() } })
                )
            case .ready:
                content
            }
        }
        .navigationTitle(connection.name)
        .navigationSubtitle(connection.serverVersion.map { "Kubernetes \($0)" } ?? "")
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to \(connection.name)…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .clusterOverview, .none:
            ClusterOverviewView(connection: connection, inspection: $inspection)
        case .workloadOverview:
            WorkloadOverviewView(connection: connection, inspection: $inspection)
        case .helmReleases:
            HelmReleasesView(connection: connection, inspection: $inspection)
        case .portForwarding:
            PortForwardListView(connection: connection)
        case .resource(let key):
            if let resource = connection.catalog.resource(forStableKey: key) {
                ResourceBrowserView(connection: connection, resource: resource, inspection: $inspection)
                    .id(key)
            } else {
                EmptyStateView(
                    title: "Resource unavailable",
                    message: "\(key) is not served by this cluster.",
                    systemImage: "questionmark.folder"
                )
            }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sailboat.circle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tint)
            Text("Loupe").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("A window into your Kubernetes clusters")
                .foregroundStyle(.secondary)

            if let error = model.configError {
                GroupBox {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .padding(6)
                }
                .frame(maxWidth: 520)
            } else if model.config.contexts.isEmpty {
                Text("No contexts found in \(model.configPaths.map(\.path).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a cluster").font(.headline).padding(.bottom, 4)
                    ForEach(model.config.contexts) { context in
                        Button {
                            model.open(contextNamed: context.name)
                        } label: {
                            HStack {
                                Image(systemName: "server.rack").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(context.name)
                                    Text(model.config.cluster(named: context.cluster)?.server ?? context.cluster)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if context.name == model.config.currentContext {
                                    Chip(text: "current", color: .accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: 460)
                .padding(16)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
