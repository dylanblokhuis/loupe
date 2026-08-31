import Foundation
import Observation

/// Top-level application state: the kubeconfig, the clusters the user has
/// opened, and which one is in front.
@MainActor
@Observable
final class AppModel {
    private(set) var config = KubeConfig()
    private(set) var configError: String?
    private(set) var configPaths: [URL] = []
    private(set) var connections: [ClusterConnection] = []
    var activeContextName: String?
    let portForwards = PortForwardManager()

    /// Persisted so reopening the app restores the same clusters.
    private static let openContextsKey = "loupe.openContexts"
    private static let activeContextKey = "loupe.activeContext"

    var activeConnection: ClusterConnection? {
        guard let activeContextName else { return nil }
        return connections.first { $0.target.contextName == activeContextName }
    }

    init() {
        loadConfig()
        restoreSession()
    }

    // MARK: Config

    func loadConfig() {
        configPaths = KubeConfigLoader.defaultPaths()
        do {
            config = try KubeConfigLoader.load(paths: configPaths)
            configError = nil
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reloadConfig() {
        loadConfig()
        // Drop connections whose context no longer exists.
        for connection in connections where config.context(named: connection.target.contextName) == nil {
            close(connection)
        }
    }

    /// Contexts grouped by the kubeconfig file that defined them.
    var contextsByFile: [(file: URL, contexts: [KubeContext])] {
        var order: [URL] = []
        var grouped: [URL: [KubeContext]] = [:]
        for context in config.contexts {
            let file = config.contextSources[context.name] ?? configPaths.first ?? URL(fileURLWithPath: "/")
            if grouped[file] == nil { order.append(file) }
            grouped[file, default: []].append(context)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    // MARK: Connections

    @discardableResult
    func open(contextNamed name: String) -> ClusterConnection? {
        if let existing = connections.first(where: { $0.target.contextName == name }) {
            activeContextName = name
            persistSession()
            return existing
        }
        guard let target = config.resolve(context: name) else { return nil }
        let connection = ClusterConnection(target: target)
        connections.append(connection)
        activeContextName = name
        persistSession()
        Task { await connection.connect() }
        return connection
    }

    func close(_ connection: ClusterConnection) {
        portForwards.stopAll(forContext: connection.target.contextName)
        connection.disconnect()
        connections.removeAll { $0 === connection }
        if activeContextName == connection.target.contextName {
            activeContextName = connections.first?.target.contextName
        }
        persistSession()
    }

    func isOpen(_ name: String) -> Bool {
        connections.contains { $0.target.contextName == name }
    }

    func connection(named name: String) -> ClusterConnection? {
        connections.first { $0.target.contextName == name }
    }

    // MARK: Metrics settings

    /// Reads from the live connection when there is one, so an edit made in
    /// Settings is reflected immediately rather than after a reconnect.
    func metricsSettings(for context: String) -> MetricsSettings {
        connection(named: context)?.metricsSettings ?? MetricsSettingsStore.load(context: context)
    }

    func updateMetricsSettings(_ settings: MetricsSettings, for context: String) {
        if let connection = connection(named: context) {
            connection.applyMetricsSettings(settings)
        } else {
            MetricsSettingsStore.save(settings, context: context)
        }
    }

    // MARK: Session persistence

    private func restoreSession() {
        let defaults = UserDefaults.standard
        // Both values are read up front: `open` persists as it goes, so the
        // saved active context would otherwise be overwritten before it is used.
        let saved = defaults.stringArray(forKey: Self.openContextsKey) ?? []
        let savedActive = defaults.string(forKey: Self.activeContextKey)
        let restorable = saved.filter { config.context(named: $0) != nil }

        for name in restorable { open(contextNamed: name) }

        if let savedActive, restorable.contains(savedActive) {
            activeContextName = savedActive
        } else if restorable.isEmpty, let current = config.currentContext,
                  config.context(named: current) != nil {
            open(contextNamed: current)
        }
        persistSession()
    }

    private func persistSession() {
        let defaults = UserDefaults.standard
        defaults.set(connections.map(\.target.contextName), forKey: Self.openContextsKey)
        defaults.set(activeContextName, forKey: Self.activeContextKey)
    }
}
