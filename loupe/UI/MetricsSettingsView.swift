import SwiftUI

/// Settings › Metrics: chooses where CPU and memory numbers come from, per
/// kubeconfig context, and lets a Prometheus endpoint stand in for a cluster
/// that has no metrics-server.
struct MetricsSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var context: String = ""
    @State private var settings = MetricsSettings()
    @State private var showsQueries = false
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    private var contexts: [String] { model.config.contexts.map(\.name) }

    private var connection: ClusterConnection? {
        model.connection(named: context)
    }

    var body: some View {
        Form {
            Section("Cluster") {
                if contexts.isEmpty {
                    Text("No contexts in the kubeconfig.")
                } else {
                    Picker("Context", selection: $context) {
                        ForEach(contexts, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Usage source", selection: $settings.provider) {
                        ForEach(MetricsProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    LabeledContent("Currently using", value: statusDescription)
                }
            }

            if settings.provider == .prometheus || settings.provider == .automatic {
                prometheusSection
                queriesSection
            }

            if let testResult {
                Section("Test") {
                    switch testResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            context = model.activeContextName ?? contexts.first ?? ""
            settings = model.metricsSettings(for: context)
        }
        .onChange(of: context) { _, newValue in
            settings = model.metricsSettings(for: newValue)
            testResult = nil
        }
        // Applied live rather than behind a Save button, but only once typing
        // pauses: adopting settings restarts the cluster's metrics poller, and
        // doing that per keystroke would flush the numbers off the overview.
        .task(id: settings) {
            guard !context.isEmpty, settings != model.metricsSettings(for: context) else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            model.updateMetricsSettings(settings, for: context)
        }
    }

    private var statusDescription: String {
        guard let connection else { return "cluster not open" }
        var description = connection.metricsSource.label
        if connection.metricsSource == .prometheus {
            description += " — \(settings.endpointDescription)"
        }
        return description
    }

    @ViewBuilder
    private var prometheusSection: some View {
        Section("Prometheus") {
            Picker("Reach it", selection: $settings.usesServiceProxy) {
                Text("Through the API server").tag(true)
                Text("At a URL").tag(false)
            }
            .pickerStyle(.radioGroup)

            if settings.usesServiceProxy {
                TextField("Namespace", text: $settings.namespace)
                TextField("Service", text: $settings.service)
                TextField("Port", text: $settings.port)
                Text("Queries go to the Prometheus Service through the API server's proxy, so the "
                     + "cluster's own credentials are reused and nothing extra is stored. This needs "
                     + "permission to `get` `services/proxy` in that namespace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("URL", text: $settings.url)
                    .font(.system(size: 11, design: .monospaced))
                Text("Sent directly, with no authentication — point this at a port-forward "
                     + "(Network › Port Forwarding) or an endpoint that does not need credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Path prefix", text: $settings.pathPrefix, prompt: Text("none"))
                .font(.system(size: 11, design: .monospaced))

            HStack {
                if settings.usesServiceProxy {
                    Button("Detect") { detect() }
                        .disabled(connection?.client == nil || isTesting)
                        .help("Look for a Prometheus Service in the cluster")
                }
                Button("Test Connection") { test() }
                    .disabled(connection?.client == nil || isTesting || !settings.isPrometheusConfigured)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
            }
            if connection?.client == nil {
                Text("Open this cluster to test the connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var queriesSection: some View {
        Section("Queries") {
            DisclosureGroup("PromQL", isExpanded: $showsQueries) {
                Text("CPU expressions must return cores and memory expressions bytes. The defaults read "
                     + "the kubelet's cAdvisor series; edit them if your scrape config labels things "
                     + "differently — usage is matched on the `node`, `namespace`, `pod` and "
                     + "`container` labels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(PrometheusQueries.fields, id: \.name) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(field.name).font(.system(size: 11, weight: .medium))
                            Text(field.unit).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        TextField("", text: Binding(
                            get: { settings.queries[keyPath: field.keyPath] },
                            set: { settings.queries[keyPath: field.keyPath] = $0 }
                        ), axis: .vertical)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1...4)
                    }
                    .padding(.vertical, 2)
                }

                Button("Restore Defaults") { settings.queries = .cAdvisor }
                    .disabled(settings.queries == .cAdvisor)
                    .padding(.top, 4)
            }
        }
    }

    private func detect() {
        guard let client = connection?.client else { return }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                guard let found = try await PrometheusDiscovery.find(client: client) else {
                    testResult = .failure("No Prometheus Service answered in this cluster. "
                                          + "Fill the fields in by hand, or use a URL.")
                    return
                }
                settings.namespace = found.namespace
                settings.service = found.service
                settings.port = found.port
                settings.pathPrefix = ""
                testResult = .success(
                    "Found Prometheus \(found.version) at \(found.namespace)/\(found.service):\(found.port)."
                )
            } catch {
                testResult = .failure(ClusterConnection.describe(error))
            }
        }
    }

    private func test() {
        guard let client = connection?.client, let prometheus = settings.makeClient(kube: client) else { return }
        let queries = settings.queries
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                let version = try await prometheus.buildVersion()
                let snapshot = try await PrometheusMetrics.load(client: prometheus, queries: queries)
                let counts = PrometheusQueries.fields
                    .map { "\($0.name) \(snapshot.counts[$0.name] ?? 0)" }
                    .joined(separator: ", ")
                let matched = "matched \(snapshot.nodes.count) nodes and \(snapshot.pods.count) pods"
                testResult = .success(
                    "Prometheus \(version ?? "reachable") — \(matched). Series returned: \(counts)."
                )
            } catch {
                testResult = .failure(ClusterConnection.describe(error))
            }
        }
    }
}
