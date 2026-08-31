import Foundation
import Observation

/// Lists and watches one resource type, keeping a live table of rows.
///
/// Columns come from the API server's Table representation — the same ones
/// `kubectl get` prints — so a resource the app has never heard of still gets
/// meaningful columns.
@MainActor
@Observable
final class ResourceListModel {
    let resource: APIResource
    private weak var connection: ClusterConnection?

    private(set) var columns: [ResourceColumn] = []
    private(set) var rows: [ResourceRow] = []
    private(set) var isLoading = false
    private(set) var isWatching = false
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?
    private(set) var truncated = false

    var searchText: String = ""
    var showWideColumns = false
    var sortColumnID: String?
    var sortAscending = true

    private var index: [String: Int] = [:]
    private var resourceVersion: String?
    private var namespaceScope: [String]?
    /// Set when the cluster-wide list was refused and the rows were gathered
    /// namespace by namespace, so the watch must be scoped the same way.
    private var listedPerNamespace: [String]?

    // Sorting the visible rows is the most expensive thing this model does and
    // the view asks for them more than once per pass, so the result is memoised
    // outside observation to avoid re-invalidating the view that reads it.
    @ObservationIgnored private var rowsVersion = 0
    @ObservationIgnored private var cachedKey: String?
    @ObservationIgnored private var cachedRows: [ResourceRow] = []
    @ObservationIgnored private var cachedSummaryVersion: Int?
    @ObservationIgnored private var cachedSummary: [ResourceHealth: Int] = [:]
    // Cancelled from `deinit`, which cannot touch main-actor state.
    @ObservationIgnored nonisolated(unsafe) private var loadTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var watchTask: Task<Void, Never>?

    private static let pageSize = 500
    private static let maximumRows = 10_000
    /// A hard stop in case a server keeps handing back a `continue` token for
    /// pages this client cannot decode.
    private static let maximumPages = 60

    init(resource: APIResource, connection: ClusterConnection) {
        self.resource = resource
        self.connection = connection
    }

    deinit {
        loadTask?.cancel()
        watchTask?.cancel()
    }

    // MARK: Lifecycle

    func start() {
        let scope = resource.namespaced ? connection?.effectiveNamespaces : nil
        if !rows.isEmpty, scope == namespaceScope, isWatching { return }
        namespaceScope = scope
        restart()
    }

    func stop() {
        loadTask?.cancel()
        watchTask?.cancel()
        loadTask = nil
        watchTask = nil
        isWatching = false
    }

    func refresh() {
        namespaceScope = resource.namespaced ? connection?.effectiveNamespaces : nil
        restart()
    }

    private func restart() {
        stop()
        loadTask = Task { [weak self] in
            await self?.load()
        }
    }

    // MARK: Listing

    private func load() async {
        guard let client = connection?.client else { return }
        isLoading = true
        errorMessage = nil
        truncated = false
        defer { isLoading = false }

        do {
            let table = try await fetchAll(client: client)
            apply(table)
            lastUpdated = Date()
            if resource.isWatchable { startWatch() }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            errorMessage = ClusterConnection.describe(error)
        }
    }

    private func fetchAll(client: KubeClient) async throws -> ResourceTable {
        let scope = namespaceScope
        listedPerNamespace = nil

        if let scope, scope.count == 1 {
            return try await fetchPaged(client: client, namespace: scope[0], keeping: nil)
        }
        do {
            // Filtering during the walk rather than after it means the row cap
            // counts rows the user will actually see.
            return try await fetchPaged(
                client: client, namespace: nil, keeping: scope.map(Set.init)
            )
        } catch let error as KubeStatusError where error.isForbidden {
            // No cluster-wide list permission. Fall back to the namespaces in
            // scope, or — when browsing "all" — to the ones the user can see.
            let namespaces = scope ?? connection?.namespaces ?? []
            guard !namespaces.isEmpty else { throw error }
            listedPerNamespace = namespaces
            var merged = ResourceTable()
            for namespace in namespaces {
                let page = try await fetchPaged(client: client, namespace: namespace, keeping: nil)
                if merged.columns.isEmpty { merged.columns = page.columns }
                merged.rows.append(contentsOf: page.rows)
                if merged.rows.count >= Self.maximumRows {
                    truncated = true
                    break
                }
            }
            // Per-namespace versions are not comparable, so the watch restarts
            // from "now" rather than from a cursor that means nothing.
            merged.resourceVersion = nil
            return merged
        }
    }

    private func fetchPaged(
        client: KubeClient, namespace: String?, keeping namespaces: Set<String>?
    ) async throws -> ResourceTable {
        var result = ResourceTable()
        var continueToken: String?
        var pages = 0
        repeat {
            var query = [
                URLQueryItem(name: "includeObject", value: "Object"),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ]
            if let continueToken { query.append(URLQueryItem(name: "continue", value: continueToken)) }

            var request = KubeRequest.get(resource.listPath(namespace: namespace), query: query)
            request.accept = KubeAccept.table
            let value = try await client.json(request)
            let page = ResourceTable.decode(value)

            if result.columns.isEmpty { result.columns = page.columns }
            if let namespaces {
                result.rows.append(contentsOf: page.rows.filter {
                    namespaces.contains($0.object.namespace ?? "")
                })
            } else {
                result.rows.append(contentsOf: page.rows)
            }
            result.resourceVersion = page.resourceVersion
            continueToken = value.string(at: "metadata.continue")

            pages += 1
            if result.rows.count >= Self.maximumRows || pages >= Self.maximumPages {
                truncated = continueToken?.isEmpty == false
                break
            }
            try Task.checkCancellation()
        } while continueToken?.isEmpty == false
        return result
    }

    private func apply(_ table: ResourceTable) {
        columns = table.columns
        rows = table.rows
        for index in rows.indices { rows[index].usage = usage(for: rows[index].object) }
        resourceVersion = table.resourceVersion
        reindex()
    }

    private func reindex() {
        index = [:]
        index.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() where index[row.id] == nil {
            index[row.id] = offset
        }
        rowsVersion &+= 1
    }

    // MARK: Usage

    /// Whether this list should carry CPU and memory columns.
    ///
    /// Only pods qualify: `podMetrics` is the one usage map keyed by something
    /// a row can be matched against, and the Table representation never carries
    /// usage for any kind.
    private var reportsUsage: Bool {
        resource.kind == "Pod" && resource.group.isEmpty && connection?.metricsAvailable == true
    }

    private func usage(for object: KubeObject) -> ResourceUsage? {
        guard reportsUsage,
              let metrics = connection?.podMetrics["\(object.namespace ?? "")/\(object.name)"]
        else { return nil }
        return ResourceUsage(cpuMillicores: metrics.cpuMillicores, memoryBytes: metrics.memoryBytes)
    }

    /// Restamps every row from the latest metrics snapshot.
    ///
    /// Metrics arrive on their own cycle, unrelated to the watch, so the view
    /// calls this when `ClusterConnection.metricsRevision` moves.
    func applyUsage() {
        guard reportsUsage else {
            guard rows.contains(where: { $0.usage != nil }) else { return }
            for index in rows.indices { rows[index].usage = nil }
            rowsVersion &+= 1
            return
        }
        for index in rows.indices { rows[index].usage = usage(for: rows[index].object) }
        rowsVersion &+= 1
    }

    // MARK: Watching

    private func startWatch() {
        guard resource.isWatchable, let client = connection?.client else { return }
        watchTask?.cancel()
        isWatching = true
        let scopes = watchScopes()
        let cursor = scopes.count == 1 ? resourceVersion : nil

        watchTask = Task { [weak self] in
            guard let self else { return }
            let expired = await withTaskGroup(of: Bool.self) { group in
                for namespace in scopes {
                    group.addTask {
                        await self.watchLoop(client: client, namespace: namespace, from: cursor)
                    }
                }
                var expired = false
                for await result in group where result {
                    expired = true
                    group.cancelAll()
                }
                return expired
            }
            self.isWatching = false
            guard !Task.isCancelled, expired else { return }
            // The cursor fell out of the server's history: re-list. Clearing the
            // handle first stops the reload's `startWatch` from cancelling the
            // task it is running on.
            self.watchTask = nil
            self.loadTask = Task { [weak self] in await self?.load() }
        }
    }

    /// The namespaces the watch must cover: the same ones the list actually
    /// read, so a cluster-wide watch is never opened after a 403 fallback.
    private func watchScopes() -> [String?] {
        if let perNamespace = listedPerNamespace, !perNamespace.isEmpty { return perNamespace }
        if let scope = namespaceScope, scope.count == 1 { return [scope[0]] }
        return [nil]
    }

    /// Watches one namespace scope until cancelled. Returns `true` when the
    /// watch cursor expired and the whole list has to be rebuilt.
    private func watchLoop(client: KubeClient, namespace: String?, from cursor: String?) async -> Bool {
        var backoff: Duration = .seconds(1)
        var cursor = cursor
        while !Task.isCancelled {
            let started = ContinuousClock.now
            let outcome = await runWatch(client: client, namespace: namespace, from: cursor)
            if Task.isCancelled { return false }

            switch outcome {
            case .expired:
                return true
            case .ended(let latest):
                cursor = latest ?? cursor
            case .failed:
                break
            }
            // A watch that stayed up is a healthy one; only genuinely flapping
            // connections should back off.
            if started.duration(to: .now) > .seconds(30) { backoff = .seconds(1) }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
        return false
    }

    private enum WatchOutcome {
        case ended(String?)
        case expired
        case failed
    }

    /// Runs one watch connection for one namespace scope.
    private func runWatch(
        client: KubeClient, namespace: String?, from cursor: String?
    ) async -> WatchOutcome {
        var query = [
            URLQueryItem(name: "watch", value: "true"),
            URLQueryItem(name: "includeObject", value: "Object"),
            URLQueryItem(name: "allowWatchBookmarks", value: "true"),
        ]
        if let cursor { query.append(URLQueryItem(name: "resourceVersion", value: cursor)) }

        var request = KubeRequest.get(resource.listPath(namespace: namespace), query: query)
        request.accept = KubeAccept.table

        var latest = cursor
        do {
            for try await line in client.lines(request) {
                guard !line.isEmpty, let event = WatchEvent.decode(line) else { continue }
                if event.type == .error {
                    return event.payload.int(at: "code") == 410 ? .expired : .failed
                }
                if let version = handle(event) { latest = version }
            }
        } catch let error as KubeStatusError {
            if error.isExpired { return .expired }
            errorMessage = error.errorDescription
            return .failed
        } catch {
            if !Task.isCancelled { errorMessage = ClusterConnection.describe(error) }
            return .failed
        }
        return .ended(latest)
    }

    @discardableResult
    private func handle(_ event: WatchEvent) -> String? {
        // Watch responses are Tables carrying a single row.
        let table = ResourceTable.decode(event.payload)
        if let version = table.resourceVersion, watchScopes().count == 1 {
            resourceVersion = version
        }
        if event.type == .bookmark { return table.resourceVersion }
        guard var row = table.rows.first else { return table.resourceVersion }
        row.usage = usage(for: row.object)

        if let scope = namespaceScope, resource.namespaced,
           let namespace = row.object.namespace, !scope.contains(namespace) {
            return table.resourceVersion
        }

        switch event.type {
        case .added, .modified:
            if let existing = index[row.id] {
                rows[existing] = row
            } else {
                rows.append(row)
                index[row.id] = rows.count - 1
            }
            rowsVersion &+= 1
        case .deleted:
            if let existing = index[row.id] {
                rows.remove(at: existing)
                reindex()
            }
        default:
            break
        }
        lastUpdated = Date()
        return table.resourceVersion
    }

    // MARK: Presentation

    var visibleColumns: [ResourceColumn] {
        showWideColumns ? columns : columns.filter { !$0.isWide }
    }

    /// The columns to draw, including the synthetic Namespace column that
    /// appears whenever more than one namespace is in scope.
    var displayColumns: [DisplayColumn] {
        var result: [DisplayColumn] = []
        let showsNamespace = resource.namespaced && (namespaceScope?.count ?? 0) != 1
        var visible = 0

        for (index, column) in columns.enumerated() {
            if !showWideColumns, column.isWide { continue }
            result.append(DisplayColumn(
                id: "\(index).\(column.name)",
                title: column.name,
                source: .server(index: index),
                description: column.description,
                weight: Self.weight(for: column.name, isFirst: visible == 0)
            ))
            if visible == 0, showsNamespace {
                result.append(DisplayColumn(
                    id: "namespace",
                    title: "Namespace",
                    source: .namespace,
                    description: "The namespace this object belongs to",
                    weight: 1.1
                ))
            }
            visible += 1
        }

        if result.isEmpty {
            result = [DisplayColumn(id: "0.Name", title: "Name", source: .server(index: 0), weight: 3)]
        }

        if reportsUsage {
            let source = connection?.metricsSource.label ?? "metrics"
            let usage: [DisplayColumn] = [ResourceUsage.Kind.cpu, .memory].map { kind in
                DisplayColumn(
                    id: "usage.\(kind.title)",
                    title: kind.title,
                    source: .usage(kind),
                    description: "\(kind.title) currently used, reported by \(source)",
                    weight: 0.7
                )
            }
            // Age reads best last, the way kubectl prints it, so the usage
            // columns go in front of it rather than after.
            if let age = result.firstIndex(where: {
                $0.title.caseInsensitiveCompare("Age") == .orderedSame
            }) {
                result.insert(contentsOf: usage, at: age)
            } else {
                result.append(contentsOf: usage)
            }
        }
        return result
    }

    private static func weight(for name: String, isFirst: Bool) -> Double {
        if isFirst { return 2.2 }
        switch name.lowercased() {
        case "age", "ready", "restarts", "replicas", "count", "type": return 0.7
        case "status", "state", "reason", "phase": return 0.9
        default: return 1
        }
    }

    /// Rows after search filtering and sorting.
    ///
    /// The result is memoised because a single body pass asks for it more than
    /// once and a locale-aware sort over thousands of rows is not cheap.
    func displayedRows(columns displayColumns: [DisplayColumn]) -> [ResourceRow] {
        let key = "\(rowsVersion)|\(searchText)|\(sortColumnID ?? "")|\(sortAscending)|\(displayColumns.count)"
        if key == cachedKey { return cachedRows }

        var result = rows
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter { row in
                if row.object.name.lowercased().contains(needle) { return true }
                if row.object.namespace?.lowercased().contains(needle) == true { return true }
                if row.cells.contains(where: { $0.lowercased().contains(needle) }) { return true }
                return row.object.labels.contains {
                    "\($0.key)=\($0.value)".lowercased().contains(needle)
                }
            }
        }

        if let sortColumnID, let column = displayColumns.first(where: { $0.id == sortColumnID }) {
            let isAge = column.title.caseInsensitiveCompare("Age") == .orderedSame
            let isNumeric = !isAge && result.prefix(20).allSatisfy {
                let value = column.value(for: $0)
                return value.isEmpty || value == "<none>" || Double(value) != nil
            }
            // The comparator must be a strict weak ordering: inverting a
            // "less than" predicate makes equal elements compare less than each
            // other in both directions, which Swift's sort treats as a bug.
            result.sort { lhs, rhs in
                var order = compare(lhs, rhs, using: column, isAge: isAge, isNumeric: isNumeric)
                if order == .orderedSame {
                    return Self.tiebreak(lhs, rhs)
                }
                if !sortAscending {
                    order = order == .orderedAscending ? .orderedDescending : .orderedAscending
                }
                return order == .orderedAscending
            }
        } else {
            result.sort(by: Self.tiebreak)
        }

        cachedKey = key
        cachedRows = result
        return result
    }

    private func compare(
        _ lhs: ResourceRow, _ rhs: ResourceRow, using column: DisplayColumn, isAge: Bool, isNumeric: Bool
    ) -> ComparisonResult {
        if case .usage(let kind) = column.source {
            // `250m` and `1.50` do not compare as text; rows with no reading
            // yet sort below every row that has one.
            let left = lhs.usage?.value(kind) ?? -.infinity
            let right = rhs.usage?.value(kind) ?? -.infinity
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        if isAge {
            // Age cells are durations; order by the real creation time, newest
            // first, which is what "ascending age" means to a reader.
            let left = lhs.object.creationTimestamp ?? .distantPast
            let right = rhs.object.creationTimestamp ?? .distantPast
            if left == right { return .orderedSame }
            return left > right ? .orderedAscending : .orderedDescending
        }
        if isNumeric {
            let left = Double(column.value(for: lhs)) ?? -.infinity
            let right = Double(column.value(for: rhs)) ?? -.infinity
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return column.value(for: lhs).localizedStandardCompare(column.value(for: rhs))
    }

    /// Deterministic fallback order so equal keys never shuffle between passes.
    private static func tiebreak(_ lhs: ResourceRow, _ rhs: ResourceRow) -> Bool {
        let left = lhs.object.namespace ?? ""
        let right = rhs.object.namespace ?? ""
        if left != right { return left < right }
        let byName = lhs.object.name.localizedStandardCompare(rhs.object.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id < rhs.id
    }

    var healthSummary: [ResourceHealth: Int] {
        // Reading `rows` before the cache check keeps the observation
        // dependency alive on a hit, so a watch update still redraws.
        let current = rows
        if cachedSummaryVersion == rowsVersion { return cachedSummary }
        var counts: [ResourceHealth: Int] = [:]
        for row in current { counts[row.object.health, default: 0] += 1 }
        cachedSummary = counts
        cachedSummaryVersion = rowsVersion
        return counts
    }

    /// Whether this kind has any state worth showing.
    ///
    /// ConfigMaps, Secrets and RBAC rules carry no status, so every row reports
    /// `.unknown` — a column of grey dots that never means anything.
    var reportsHealth: Bool {
        healthSummary.contains { $0.key != .unknown && $0.value > 0 }
    }
}
