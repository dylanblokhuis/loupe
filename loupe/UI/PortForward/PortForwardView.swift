import AppKit
import SwiftUI

/// Lists every tunnel open for the active cluster.
struct PortForwardListView: View {
    let connection: ClusterConnection
    @Environment(AppModel.self) private var model

    private var sessions: [PortForwardSession] {
        model.portForwards.sessions(forContext: connection.target.contextName)
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                EmptyStateView(
                    title: "No port forwards",
                    message: "Open a pod and choose Forward Port to tunnel one of its container "
                        + "ports to localhost.",
                    systemImage: "arrow.left.arrow.right"
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        PortForwardRow(session: session) {
                            model.portForwards.stop(session)
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
            }
        }
        .navigationTitle("Port Forwarding")
        .toolbar {
            if !sessions.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Stop All", systemImage: "stop.circle") {
                        model.portForwards.stopAll(forContext: connection.target.contextName)
                    }
                }
            }
        }
    }
}

struct PortForwardRow: View {
    let session: PortForwardSession
    var stop: () -> Void

    private var tint: Color {
        switch session.state {
        case .active: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("127.0.0.1:\(String(session.localPort))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("\(session.podName):\(String(session.remotePort))")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(session.namespace).font(.system(size: 10)).foregroundStyle(.secondary)
                    if !session.label.isEmpty {
                        Chip(text: session.label, color: .secondary)
                    }
                    if session.activeConnections > 0 {
                        Chip(text: "\(session.activeConnections) open", color: .green)
                    }
                    if session.totalConnections > 0 {
                        Text("\(session.totalConnections) total")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if case .failed(let message) = session.state {
                        Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
                    }
                }
            }

            Spacer()

            Button {
                if let url = URL(string: session.url) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help("Open \(session.url)")
            .disabled(session.state != .active)

            Button {
                ResourceActions.copyToPasteboard(session.url)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy address")

            Button(action: stop) {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop forwarding")
        }
        .padding(.vertical, 3)
    }
}

/// Picks which container port to forward and where to expose it.
struct PortForwardSheet: View {
    let pod: KubeObject
    var start: (_ remotePort: Int, _ localPort: Int, _ label: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var remotePort: Int
    @State private var localPort: String
    @State private var label: String

    private struct ContainerPort: Identifiable, Hashable {
        var container: String
        var name: String?
        var port: Int
        var id: String { "\(container)/\(port)" }
        var title: String {
            name.map { "\(port) · \($0) (\(container))" } ?? "\(port) (\(container))"
        }
    }

    private var ports: [ContainerPort] {
        pod.raw.array(at: "spec.containers").flatMap { container -> [ContainerPort] in
            let name = container.string(at: "name") ?? "?"
            return container.array(at: "ports").compactMap { entry in
                guard let port = entry.int(at: "containerPort") else { return nil }
                return ContainerPort(container: name, name: entry.string(at: "name"), port: port)
            }
        }
    }

    init(pod: KubeObject, start: @escaping (Int, Int, String) -> Void) {
        self.pod = pod
        self.start = start
        let first = pod.raw.array(at: "spec.containers")
            .compactMap { $0.array(at: "ports").first?.int(at: "containerPort") }
            .first ?? 80
        self._remotePort = State(wrappedValue: first)
        self._localPort = State(wrappedValue: String(first))
        self._label = State(wrappedValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Forward a port").font(.headline)
                Text(pod.qualifiedName).font(.caption).foregroundStyle(.secondary)
            }

            Form {
                if ports.isEmpty {
                    LabeledContent("Container port") {
                        TextField("", value: $remotePort, format: .number)
                            .frame(width: 90)
                    }
                    Text("This pod declares no container ports; enter one manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Container port", selection: $remotePort) {
                        ForEach(ports) { entry in
                            Text(entry.title).tag(entry.port)
                        }
                    }
                    .onChange(of: remotePort) { _, newValue in localPort = String(newValue) }
                }
                LabeledContent("Local port") {
                    TextField("0 for any", text: $localPort).frame(width: 90)
                }
                LabeledContent("Label") {
                    TextField("optional", text: $label)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("The tunnel listens on 127.0.0.1 only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Forward") {
                    start(remotePort, Int(localPort) ?? 0, label)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 430)
    }
}
