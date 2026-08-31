import SwiftUI

/// Identifies what a standalone log window is showing. Codable so macOS can
/// restore the window across launches.
struct LogsWindowRequest: Hashable, Codable {
    let contextName: String
    let namespace: String
    /// `Pod`, or a controller kind whose pods are merged into one log.
    let kind: String
    let name: String
}

/// A detached log viewer: resolves the cluster connection by context name and
/// fetches the object fresh, since a restored window outlives any KubeObject
/// the inspector held.
struct LogsWindow: View {
    let request: LogsWindowRequest

    @Environment(AppModel.self) private var model

    @State private var scope: LogScope?
    @State private var errorMessage: String?

    private var connection: ClusterConnection? {
        model.connections.first { $0.target.contextName == request.contextName }
    }

    var body: some View {
        Group {
            if let connection, let scope {
                LogsView(connection: connection, scope: scope, isDetached: true)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Logs Unavailable",
                    systemImage: "text.line.magnify",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("\(request.name) — Logs")
        .navigationSubtitle("\(request.namespace) · \(request.contextName)")
        .task { await load() }
    }

    private func load() async {
        // At launch a restored window can beat the cluster's reconnect, so
        // wait for the client rather than failing on the race.
        for _ in 0..<50 {
            if case .failed(let message) = connection?.state {
                errorMessage = message
                return
            }
            if let connection, let client = connection.client {
                do {
                    let raw = try await client.get(path: try itemPath(connection: connection))
                    guard let resolved = LogScope.best(for: KubeObject(raw)) else {
                        errorMessage = "\(request.kind) has no pods to read logs from."
                        return
                    }
                    scope = resolved
                } catch {
                    errorMessage = ClusterConnection.describe(error)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        errorMessage = "Cluster \"\(request.contextName)\" is not connected."
    }

    /// The kind is looked up in discovery so the window works for any
    /// controller, not just the core ones whose paths could be hardcoded.
    private func itemPath(connection: ClusterConnection) throws -> String {
        if request.kind == "Pod" {
            return "/api/v1/namespaces/\(request.namespace)/pods/\(request.name)"
        }
        guard let resource = connection.catalog.resource(kind: request.kind) else {
            throw ActionError.message("This cluster does not serve \(request.kind).")
        }
        return resource.itemPath(namespace: request.namespace, name: request.name)
    }
}
