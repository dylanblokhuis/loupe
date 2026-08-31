import Foundation

/// One series returned by an instant query.
struct PrometheusSample: Sendable {
    var labels: [String: String]
    var value: Double
}

enum PrometheusError: Error, LocalizedError {
    case query(String)
    case badResponse
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .query(let message): return message
        case .badResponse: return "Prometheus returned something that is not a query result."
        case .unreachable(let message): return message
        }
    }
}

/// A minimal client for the Prometheus HTTP API — instant queries only, which
/// is all that "what is this pod using right now" needs.
///
/// The default route goes through the API server's service proxy, so the
/// cluster's existing credentials and TLS settings are reused and the app never
/// has to hold a second secret. A direct URL is there for a port-forward or an
/// endpoint that needs no authentication.
struct PrometheusClient: Sendable {
    enum Route: Sendable, Equatable {
        case serviceProxy(namespace: String, service: String, port: String)
        case direct(URL)
    }

    let route: Route
    let pathPrefix: String
    let kube: KubeClient

    /// Shared because a client is rebuilt on every refresh; a fresh session per
    /// poll would throw away connection reuse.
    private static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": KubeClient.userAgent]
        return URLSession(configuration: configuration)
    }()

    /// `/prometheus` and `prometheus/` both mean the same thing to a user.
    private var normalizedPrefix: String {
        var prefix = pathPrefix.trimmingCharacters(in: .whitespaces)
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard !prefix.isEmpty else { return "" }
        return prefix.hasPrefix("/") ? prefix : "/" + prefix
    }

    // MARK: Requests

    private func json(path: String, query: [URLQueryItem]) async throws -> JSONValue {
        switch route {
        case .serviceProxy(let namespace, let service, let port):
            let proxy = "/api/v1/namespaces/\(namespace)/services/\(service):\(port)/proxy"
            return try await kube.get(path: proxy + normalizedPrefix + path, query: query)
        case .direct(let base):
            guard var components = URLComponents(
                url: base.appending(path: normalizedPrefix + path), resolvingAgainstBaseURL: false
            ) else {
                throw PrometheusError.unreachable("\(base.absoluteString) is not a usable Prometheus URL.")
            }
            components.queryItems = query
            guard let url = components.url else {
                throw PrometheusError.unreachable("\(base.absoluteString) is not a usable Prometheus URL.")
            }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.directSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PrometheusError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                // Prometheus reports query errors in a JSON body even on 4xx.
                if let parsed = try? JSONParser.parse(data), let message = parsed.string(at: "error") {
                    throw PrometheusError.query(message)
                }
                throw PrometheusError.unreachable(
                    "Prometheus answered \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))."
                )
            }
            return try JSONParser.parse(data)
        }
    }

    /// Runs an instant query and returns its vector result.
    func instant(_ query: String) async throws -> [PrometheusSample] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response = try await json(path: "/api/v1/query", query: [URLQueryItem(name: "query", value: trimmed)])
        guard let status = response.string(at: "status") else { throw PrometheusError.badResponse }
        guard status == "success" else {
            throw PrometheusError.query(response.string(at: "error") ?? "The query was rejected.")
        }
        return response.array(at: "data.result").compactMap { item in
            // `value` is `[unixSeconds, "<number as a string>"]`.
            guard let raw = item.array(at: "value").last?.stringValue,
                  let value = Double(raw), value.isFinite
            else { return nil }
            var labels: [String: String] = [:]
            for pair in item.object(at: "metric")?.pairs ?? [] {
                labels[pair.key] = pair.value.displayString
            }
            return PrometheusSample(labels: labels, value: value)
        }
    }

    /// The server's own version, used to prove the endpoint really is Prometheus.
    func buildVersion() async throws -> String? {
        let response = try await json(path: "/api/v1/status/buildinfo", query: [])
        return response.string(at: "data.version")
    }
}

// MARK: - Finding Prometheus in the cluster

/// Locates a Prometheus Service so the endpoint does not have to be typed from
/// memory. Deployments disagree about where it lives — `monitoring`,
/// `prometheus`, `kube-prometheus-stack`, Lens's `lens-metrics` — so candidates
/// are ranked by name and then confirmed by asking each one for its build info.
enum PrometheusDiscovery {
    struct Candidate: Sendable {
        var namespace: String
        var service: String
        var port: String
        var version: String
    }

    static func find(client: KubeClient) async throws -> Candidate? {
        let services = try await client.get(
            path: "/api/v1/services",
            query: [URLQueryItem(name: "limit", value: "1000")]
        )

        var ranked: [(score: Int, namespace: String, service: String, port: String)] = []
        for item in services.array(at: "items") {
            guard let name = item.string(at: "metadata.name"),
                  let namespace = item.string(at: "metadata.namespace") else { continue }
            let lowered = name.lowercased()
            // Exclude the operator, the alert router and the exporters: they
            // answer on similar ports but serve a different API.
            guard lowered.contains("prometheus"),
                  !lowered.contains("operator"), !lowered.contains("alertmanager"),
                  !lowered.contains("exporter"), !lowered.contains("adapter"),
                  !lowered.contains("pushgateway")
            else { continue }
            guard let port = queryPort(of: item) else { continue }

            var score = 0
            if lowered == "prometheus" || lowered.hasSuffix("-prometheus") { score += 3 }
            if lowered.contains("operated") || lowered.contains("server") { score += 2 }
            if ["monitoring", "lens-metrics", "prometheus", "observability"].contains(namespace) { score += 1 }
            ranked.append((score, namespace, name, port))
        }
        ranked.sort { ($0.score, $1.namespace) > ($1.score, $0.namespace) }

        for entry in ranked.prefix(6) {
            let probe = PrometheusClient(
                route: .serviceProxy(namespace: entry.namespace, service: entry.service, port: entry.port),
                pathPrefix: "",
                kube: client
            )
            guard let version = try? await probe.buildVersion() else { continue }
            return Candidate(
                namespace: entry.namespace, service: entry.service, port: entry.port, version: version
            )
        }
        return nil
    }

    /// The port the HTTP API is served on: a named web port when there is one,
    /// otherwise 9090, otherwise whatever the Service's first port is.
    private static func queryPort(of service: JSONValue) -> String? {
        let ports = service.array(at: "spec.ports")
        for port in ports {
            let name = port.string(at: "name")?.lowercased() ?? ""
            if ["web", "http-web", "http", "api"].contains(name), let number = port.int(at: "port") {
                return String(number)
            }
        }
        if ports.contains(where: { $0.int(at: "port") == 9090 }) { return "9090" }
        return ports.first.flatMap { $0.int(at: "port") }.map(String.init)
    }
}

// MARK: - Mapping query results onto the app's metric types

enum PrometheusMetrics {
    struct Snapshot: Sendable {
        var nodes: [String: NodeMetrics] = [:]
        var pods: [String: PodMetrics] = [:]
        /// Series counts per query, so the settings screen can say what worked.
        var counts: [String: Int] = [:]
    }

    /// Runs all six queries concurrently and folds them into the same shapes
    /// `ClusterConnection` builds from metrics-server.
    ///
    /// A query that fails is fatal — silently reporting half the cluster's
    /// usage is worse than saying the source is broken.
    static func load(client: PrometheusClient, queries: PrometheusQueries) async throws -> Snapshot {
        async let nodeCPU = client.instant(queries.nodeCPU)
        async let nodeMemory = client.instant(queries.nodeMemory)
        async let podCPU = client.instant(queries.podCPU)
        async let podMemory = client.instant(queries.podMemory)
        async let containerCPU = client.instant(queries.containerCPU)
        async let containerMemory = client.instant(queries.containerMemory)

        let results = try await (
            nodeCPU: nodeCPU, nodeMemory: nodeMemory,
            podCPU: podCPU, podMemory: podMemory,
            containerCPU: containerCPU, containerMemory: containerMemory
        )

        var snapshot = Snapshot()
        snapshot.counts = [
            "Node CPU": results.nodeCPU.count,
            "Node memory": results.nodeMemory.count,
            "Pod CPU": results.podCPU.count,
            "Pod memory": results.podMemory.count,
            "Container CPU": results.containerCPU.count,
            "Container memory": results.containerMemory.count,
        ]

        var nodes: [String: NodeMetrics] = [:]
        for sample in results.nodeCPU {
            guard let node = nodeName(sample.labels) else { continue }
            nodes[node, default: NodeMetrics(cpuMillicores: 0, memoryBytes: 0)].cpuMillicores
                += sample.value * 1_000
        }
        for sample in results.nodeMemory {
            guard let node = nodeName(sample.labels) else { continue }
            nodes[node, default: NodeMetrics(cpuMillicores: 0, memoryBytes: 0)].memoryBytes += sample.value
        }
        snapshot.nodes = nodes

        var pods: [String: PodMetrics] = [:]
        func pod(_ key: String) -> PodMetrics {
            pods[key] ?? PodMetrics(cpuMillicores: 0, memoryBytes: 0, containers: [:])
        }
        for sample in results.podCPU {
            guard let key = podKey(sample.labels) else { continue }
            var entry = pod(key)
            entry.cpuMillicores += sample.value * 1_000
            pods[key] = entry
        }
        for sample in results.podMemory {
            guard let key = podKey(sample.labels) else { continue }
            var entry = pod(key)
            entry.memoryBytes += sample.value
            pods[key] = entry
        }
        for sample in results.containerCPU {
            guard let key = podKey(sample.labels), let container = containerName(sample.labels) else { continue }
            var entry = pod(key)
            let existing = entry.containers[container] ?? (0, 0)
            entry.containers[container] = (existing.0 + sample.value * 1_000, existing.1)
            pods[key] = entry
        }
        for sample in results.containerMemory {
            guard let key = podKey(sample.labels), let container = containerName(sample.labels) else { continue }
            var entry = pod(key)
            let existing = entry.containers[container] ?? (0, 0)
            entry.containers[container] = (existing.0, existing.1 + sample.value)
            pods[key] = entry
        }
        snapshot.pods = pods

        return snapshot
    }

    // MARK: Label conventions
    //
    // Which label carries the node or pod name depends on how the scrape config
    // relabels cAdvisor's output, so each of the names in common use is tried.
    // `instance` is deliberately not one of them: it holds an address, not a
    // node name, and matching it against node names would attach usage to the
    // wrong row rather than to none.

    private static func nodeName(_ labels: [String: String]) -> String? {
        for key in ["node", "kubernetes_node", "nodename", "kubernetes_io_hostname"] {
            if let value = labels[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func podKey(_ labels: [String: String]) -> String? {
        let namespace = labels["namespace"] ?? labels["namespace_name"] ?? ""
        guard let pod = labels["pod"] ?? labels["pod_name"], !pod.isEmpty, !namespace.isEmpty else { return nil }
        return "\(namespace)/\(pod)"
    }

    private static func containerName(_ labels: [String: String]) -> String? {
        guard let name = labels["container"] ?? labels["container_name"], !name.isEmpty else { return nil }
        return name
    }
}
