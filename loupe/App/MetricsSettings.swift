import Foundation

/// Where the app reads live CPU and memory usage from.
enum MetricsProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// metrics-server when the cluster serves `metrics.k8s.io`, Prometheus
    /// otherwise. This is what a cluster gets before anyone configures it.
    case automatic
    case metricsServer
    case prometheus
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .metricsServer: return "metrics-server"
        case .prometheus: return "Prometheus"
        case .off: return "Off"
        }
    }
}

/// The PromQL the app runs to fill the same numbers metrics-server would give.
///
/// CPU expressions must return **cores** and memory expressions **bytes**, which
/// is what the raw cAdvisor series already report; the app converts cores to
/// millicores itself so an edited query does not have to remember to.
struct PrometheusQueries: Codable, Equatable, Sendable {
    var nodeCPU: String
    var nodeMemory: String
    var podCPU: String
    var podMemory: String
    var containerCPU: String
    var containerMemory: String

    /// Defaults built on the kubelet's own cAdvisor endpoint, which any
    /// Prometheus scraping a Kubernetes cluster almost certainly collects.
    ///
    /// Two details make them portable across scrape configurations:
    ///
    /// - They group by `node` *and* `kubernetes_io_hostname`. Which of the two
    ///   carries the node's name depends on how the job relabels its targets,
    ///   and Prometheus drops whichever is absent, so grouping by both lands on
    ///   the one that exists instead of collapsing every node into one series.
    /// - The node expressions prefer the root cgroup (`id="/"`), which is the
    ///   whole machine, and fall back with `or` to the sum of the node's
    ///   containers — kube-prometheus-stack drops the imageless root series, so
    ///   without the fallback it would report nothing at all.
    static let cAdvisor = PrometheusQueries(
        nodeCPU: #"sum by (node, kubernetes_io_hostname) (rate(container_cpu_usage_seconds_total{id="/"}[2m]))"#
            + #" or sum by (node, kubernetes_io_hostname) "#
            + #"(rate(container_cpu_usage_seconds_total{container!=""}[2m]))"#,
        nodeMemory: #"sum by (node, kubernetes_io_hostname) (container_memory_working_set_bytes{id="/"})"#
            + #" or sum by (node, kubernetes_io_hostname) "#
            + #"(container_memory_working_set_bytes{container!=""})"#,
        podCPU: #"sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!=""}[2m]))"#,
        podMemory: #"sum by (namespace, pod) (container_memory_working_set_bytes{container!=""})"#,
        containerCPU:
            #"sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{container!=""}[2m]))"#,
        containerMemory:
            #"sum by (namespace, pod, container) (container_memory_working_set_bytes{container!=""})"#
    )

    /// Field-by-field metadata so the settings form does not have to repeat it.
    static let fields: [(name: String, keyPath: WritableKeyPath<PrometheusQueries, String>, unit: String)] = [
        ("Node CPU", \.nodeCPU, "cores, by node"),
        ("Node memory", \.nodeMemory, "bytes, by node"),
        ("Pod CPU", \.podCPU, "cores, by namespace + pod"),
        ("Pod memory", \.podMemory, "bytes, by namespace + pod"),
        ("Container CPU", \.containerCPU, "cores, by namespace + pod + container"),
        ("Container memory", \.containerMemory, "bytes, by namespace + pod + container"),
    ]
}

/// Per-context metrics configuration.
struct MetricsSettings: Codable, Equatable, Sendable {
    var provider: MetricsProvider = .automatic

    /// Reaching Prometheus through the API server's service proxy reuses the
    /// cluster's own credentials and TLS, so there is no second set of secrets
    /// to configure or store. The direct URL is for a port-forward or an
    /// unauthenticated endpoint.
    var usesServiceProxy = true
    var namespace = "monitoring"
    var service = "prometheus-operated"
    var port = "9090"
    var url = "http://localhost:9090"
    /// Set when Prometheus is served under a sub-path, e.g. `/prometheus`.
    var pathPrefix = ""
    var queries = PrometheusQueries.cAdvisor

    /// Coding is hand-rolled so a settings blob written by an older build — one
    /// that had fewer keys — still decodes instead of resetting everything.
    private enum CodingKeys: String, CodingKey {
        case provider, usesServiceProxy, namespace, service, port, url, pathPrefix, queries
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MetricsSettings()
        provider = try container.decodeIfPresent(MetricsProvider.self, forKey: .provider) ?? defaults.provider
        usesServiceProxy = try container.decodeIfPresent(Bool.self, forKey: .usesServiceProxy)
            ?? defaults.usesServiceProxy
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace) ?? defaults.namespace
        service = try container.decodeIfPresent(String.self, forKey: .service) ?? defaults.service
        port = try container.decodeIfPresent(String.self, forKey: .port) ?? defaults.port
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? defaults.url
        pathPrefix = try container.decodeIfPresent(String.self, forKey: .pathPrefix) ?? defaults.pathPrefix
        queries = try container.decodeIfPresent(PrometheusQueries.self, forKey: .queries) ?? defaults.queries
    }

    /// True when the Prometheus fields name somewhere the app could actually
    /// reach, which is what makes `.automatic` willing to fall back to it.
    var isPrometheusConfigured: Bool { route != nil }

    var route: PrometheusClient.Route? {
        if usesServiceProxy {
            let namespace = namespace.trimmingCharacters(in: .whitespaces)
            let service = service.trimmingCharacters(in: .whitespaces)
            let port = port.trimmingCharacters(in: .whitespaces)
            guard !namespace.isEmpty, !service.isEmpty, !port.isEmpty else { return nil }
            return .serviceProxy(namespace: namespace, service: service, port: port)
        }
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), parsed.host != nil else {
            return nil
        }
        return .direct(parsed)
    }

    func makeClient(kube: KubeClient) -> PrometheusClient? {
        guard let route else { return nil }
        return PrometheusClient(route: route, pathPrefix: pathPrefix, kube: kube)
    }

    /// How the endpoint should be described in the UI.
    var endpointDescription: String {
        switch route {
        case .serviceProxy(let namespace, let service, let port):
            return "\(namespace)/\(service):\(port) via the API server"
        case .direct(let url):
            return url.absoluteString
        case nil:
            return "not configured"
        }
    }
}

/// Persists `MetricsSettings` per kubeconfig context.
///
/// One JSON blob under one key: the whole map is small, and writing it whole
/// avoids a half-migrated set of per-context keys when the shape changes.
enum MetricsSettingsStore {
    private static let key = "loupe.metricsSettings"

    static func all() -> [String: MetricsSettings] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: MetricsSettings].self, from: data)
        else { return [:] }
        return decoded
    }

    static func load(context: String) -> MetricsSettings {
        all()[context] ?? MetricsSettings()
    }

    static func save(_ settings: MetricsSettings, context: String) {
        var map = all()
        map[context] = settings
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
