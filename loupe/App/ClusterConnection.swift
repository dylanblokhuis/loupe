import Foundation
import Observation

/// Live state for one kubeconfig context: its client, discovery results,
/// namespaces and cluster-wide metrics.
@MainActor
@Observable
final class ClusterConnection: Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
        var errorMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    let target: KubeTarget
    var id: String { target.contextName }
    var name: String { target.contextName }

    private(set) var client: KubeClient?
    private(set) var state: State = .idle
    private(set) var catalog = APICatalog()
    private(set) var navigation: [NavGroup] = []
    private(set) var serverVersion: String?
    private(set) var namespaces: [String] = []
    private(set) var warnings: [String] = []
    private(set) var metricsAvailable = false
    private(set) var nodeMetrics: [String: NodeMetrics] = [:]
    private(set) var podMetrics: [String: PodMetrics] = [:]
    private(set) var helmAvailable = false

    /// Empty means "all namespaces". Persisted per context so a relaunch
    /// reopens the same slice of the cluster.
    var selectedNamespaces: Set<String> = [] {
        didSet {
            namespaceSelectionChanged.toggle()
            persistNamespaceSelection()
        }
    }
    /// Flipped whenever the namespace filter changes so views can react.
    private(set) var namespaceSelectionChanged = false

    // Cancelled from `deinit`, which cannot touch main-actor state.
    /// Bumped by every connect and disconnect so a slow attempt that has been
    /// superseded cannot write the final state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored nonisolated(unsafe) private var metricsTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var namespaceWatchTask: Task<Void, Never>?

    init(target: KubeTarget) {
        self.target = target
        // Property observers do not fire in init, so none of these restore
        // paths write the selection back.
        if let saved = Self.savedNamespaceSelections()[target.contextName] {
            selectedNamespaces = Set(saved)
        } else if let namespace = target.namespace, !namespace.isEmpty {
            // A context that names a namespace opens scoped to it; one that
            // names none opens across the whole cluster.
            selectedNamespaces = [namespace]
        }
    }

    deinit {
        metricsTask?.cancel()
        namespaceWatchTask?.cancel()
    }

    // MARK: Lifecycle

    func connect() async {
        guard state != .connecting, state != .ready else { return }
        generation += 1
        let token = generation
        state = .connecting
        warnings = []

        // Constructing the client can shell out to openssl to build a client
        // identity, so it must not run on the main actor.
        let client: KubeClient
        do {
            let target = self.target
            client = try await Task.detached(priority: .userInitiated) {
                try KubeClient(target: target)
            }.value
        } catch {
            guard token == generation else { return }
            state = .failed(Self.describe(error))
            return
        }
        guard token == generation else {
            client.invalidate()
            return
        }
        self.client = client
        warnings = client.tlsWarnings

        do {
            let version = try await client.serverVersion()
            serverVersion = version.string(at: "gitVersion")
            catalog = try await APIDiscovery.load(client: client)
            helmAvailable = catalog.supports(kind: "Secret")
            navigation = NavigationCatalog.build(catalog: catalog, includeHelm: helmAvailable)
            guard token == generation else { return }
            metricsAvailable = catalog.groupVersions.contains { $0.hasPrefix("metrics.k8s.io/") }
            state = .ready
        } catch {
            guard token == generation else { return }
            state = .failed(Self.describe(error))
            return
        }

        await loadNamespaces()
        guard token == generation else { return }
        startMetricsRefresh()
    }

    func disconnect() {
        generation += 1
        metricsTask?.cancel()
        metricsTask = nil
        namespaceWatchTask?.cancel()
        namespaceWatchTask = nil
        client?.invalidate()
        client = nil
        state = .idle
        catalog = APICatalog()
        navigation = []
        namespaces = []
        nodeMetrics = [:]
        podMetrics = [:]
    }

    func reconnect() async {
        disconnect()
        await connect()
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let status = error as? KubeStatusError { return status.errorDescription ?? "\(status.code)" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                return "TLS handshake failed — the cluster certificate could not be verified."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot reach the API server."
            case .timedOut:
                return "The connection to the API server timed out."
            default:
                return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Namespaces

    func loadNamespaces() async {
        guard let client, catalog.supports(kind: "Namespace") else { return }
        do {
            let list = try await client.get(
                path: "/api/v1/namespaces",
                query: [URLQueryItem(name: "limit", value: "1000")]
            )
            namespaces = list.array(at: "items")
                .compactMap { $0.string(at: "metadata.name") }
                .sorted()
            // A restored selection can name namespaces that no longer exist;
            // keep only the live ones so lists are not scoped to ghosts.
            let live = selectedNamespaces.intersection(namespaces)
            if live != selectedNamespaces { selectedNamespaces = live }
        } catch {
            // Users scoped to a single namespace cannot list them; fall back to
            // the namespace the context declares without discarding whatever
            // the user had already selected.
            namespaces = [target.defaultNamespace]
            if selectedNamespaces.isEmpty {
                selectedNamespaces = [target.defaultNamespace]
            }
        }
    }

    /// The namespaces a list request should cover, or `nil` for cluster-wide.
    var effectiveNamespaces: [String]? {
        selectedNamespaces.isEmpty ? nil : selectedNamespaces.sorted()
    }

    /// One dictionary keyed by context name; an empty array is a deliberate
    /// "all namespaces" and is distinct from having nothing saved.
    private static let namespaceSelectionsKey = "loupe.selectedNamespaces"

    private static func savedNamespaceSelections() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: namespaceSelectionsKey) as? [String: [String]] ?? [:]
    }

    private func persistNamespaceSelection() {
        var all = Self.savedNamespaceSelections()
        all[target.contextName] = selectedNamespaces.sorted()
        UserDefaults.standard.set(all, forKey: Self.namespaceSelectionsKey)
    }

    // MARK: Metrics

    private func startMetricsRefresh() {
        guard metricsAvailable else { return }
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetrics()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refreshMetrics() async {
        guard let client, metricsAvailable else { return }
        async let nodes = try? client.get(path: "/apis/metrics.k8s.io/v1beta1/nodes")
        async let pods = try? client.get(path: "/apis/metrics.k8s.io/v1beta1/pods")

        if let nodes = await nodes {
            var result: [String: NodeMetrics] = [:]
            for item in nodes.array(at: "items") {
                guard let name = item.string(at: "metadata.name") else { continue }
                result[name] = NodeMetrics(
                    cpuMillicores: Quantity.millicores(item.string(at: "usage.cpu")),
                    memoryBytes: Quantity.bytes(item.string(at: "usage.memory"))
                )
            }
            nodeMetrics = result
        }
        if let pods = await pods {
            var result: [String: PodMetrics] = [:]
            for item in pods.array(at: "items") {
                guard let name = item.string(at: "metadata.name"),
                      let namespace = item.string(at: "metadata.namespace") else { continue }
                var cpu = 0.0
                var memory = 0.0
                var containers: [String: (Double, Double)] = [:]
                for container in item.array(at: "containers") {
                    let containerCPU = Quantity.millicores(container.string(at: "usage.cpu"))
                    let containerMemory = Quantity.bytes(container.string(at: "usage.memory"))
                    cpu += containerCPU
                    memory += containerMemory
                    if let containerName = container.string(at: "name") {
                        containers[containerName] = (containerCPU, containerMemory)
                    }
                }
                result["\(namespace)/\(name)"] = PodMetrics(
                    cpuMillicores: cpu, memoryBytes: memory, containers: containers
                )
            }
            podMetrics = result
        }
    }
}

struct NodeMetrics: Sendable, Hashable {
    var cpuMillicores: Double
    var memoryBytes: Double
}

struct PodMetrics: Sendable {
    var cpuMillicores: Double
    var memoryBytes: Double
    var containers: [String: (Double, Double)]
}
