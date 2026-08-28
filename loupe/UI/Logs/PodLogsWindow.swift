import SwiftUI

/// Identifies a pod's logs for a standalone window. Codable so macOS can
/// restore the window across launches.
struct PodLogsWindowRequest: Hashable, Codable {
    let contextName: String
    let namespace: String
    let podName: String
}

/// A detached log viewer: resolves the cluster connection by context name and
/// fetches the pod fresh, since a restored window outlives any KubeObject the
/// inspector held.
struct PodLogsWindow: View {
    let request: PodLogsWindowRequest

    @Environment(AppModel.self) private var model

    @State private var pod: KubeObject?
    @State private var errorMessage: String?

    private var connection: ClusterConnection? {
        model.connections.first { $0.target.contextName == request.contextName }
    }

    var body: some View {
        Group {
            if let connection, let pod {
                PodLogsView(connection: connection, pod: pod, isDetached: true)
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
        .navigationTitle("\(request.podName) — Logs")
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
            if let client = connection?.client {
                do {
                    let raw = try await client.get(
                        path: "/api/v1/namespaces/\(request.namespace)/pods/\(request.podName)"
                    )
                    pod = KubeObject(raw)
                } catch {
                    errorMessage = ClusterConnection.describe(error)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        errorMessage = "Cluster \"\(request.contextName)\" is not connected."
    }
}
