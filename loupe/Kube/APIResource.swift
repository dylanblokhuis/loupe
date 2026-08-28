import Foundation

/// One resource type exposed by an API server, as reported by discovery.
struct APIResource: Identifiable, Hashable, Sendable {
    var group: String
    var version: String
    /// Plural, lowercase, e.g. `deployments`.
    var name: String
    var singularName: String
    var kind: String
    var namespaced: Bool
    var verbs: [String]
    var shortNames: [String]
    var categories: [String]
    var subresources: [String]

    var id: String { "\(groupVersion)|\(name)" }
    var groupVersion: String { group.isEmpty ? version : "\(group)/\(version)" }

    /// `apps.v1.deployments` style key used for sidebar identity and state.
    var stableKey: String { group.isEmpty ? "core.\(version).\(name)" : "\(group).\(version).\(name)" }

    var apiRoot: String { group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)" }

    var isListable: Bool { verbs.contains("list") }
    var isWatchable: Bool { verbs.contains("watch") }
    var isDeletable: Bool { verbs.contains("delete") }
    var isEditable: Bool { verbs.contains("update") || verbs.contains("patch") }

    func listPath(namespace: String?) -> String {
        if namespaced, let namespace, !namespace.isEmpty {
            return "\(apiRoot)/namespaces/\(namespace)/\(name)"
        }
        return "\(apiRoot)/\(name)"
    }

    func itemPath(namespace: String?, name itemName: String) -> String {
        "\(listPath(namespace: namespaced ? namespace : nil))/\(itemName)"
    }

    /// Human label for the sidebar, e.g. `PodDisruptionBudgets`.
    ///
    /// A few kinds are already plural (`Endpoints`), which discovery reveals by
    /// giving them a plural resource name identical to the kind.
    var displayName: String {
        if name.caseInsensitiveCompare(kind) == .orderedSame { return kind }
        return Self.pluralDisplayName(for: kind)
    }

    static func pluralDisplayName(for kind: String) -> String {
        if kind.hasSuffix("s") || kind.hasSuffix("x") || kind.hasSuffix("ch") || kind.hasSuffix("sh") {
            return kind + "es"
        }
        if kind.hasSuffix("y"), let last = kind.dropLast().last, !"aeiouAEIOU".contains(last) {
            return kind.dropLast() + "ies"
        }
        return kind + "s"
    }
}

/// The catalog of everything a cluster can serve, plus lookup helpers.
struct APICatalog: Sendable {
    var resources: [APIResource] = []
    var groupVersions: [String] = []

    /// Browsable resources: listable, not a subresource, and not one of the
    /// write-only bridge endpoints that make no sense in a list view.
    ///
    /// A resource served at several versions appears once, at the version
    /// discovery listed first — which is the server's preferred one.
    var browsable: [APIResource] {
        let hidden: Set<String> = [
            "bindings", "componentstatuses", "localsubjectaccessreviews", "selfsubjectaccessreviews",
            "selfsubjectrulesreviews", "subjectaccessreviews", "selfsubjectreviews",
            "tokenreviews", "tokenrequests",
        ]
        // `events.k8s.io/events` mirrors the core resource; showing both would
        // put a second, identical "Events" entry under Custom Resources.
        let shadowed: Set<String> = ["events.k8s.io|events"]
        var seen: Set<String> = []
        return resources.filter { resource in
            guard resource.isListable, !hidden.contains(resource.name) else { return false }
            let key = "\(resource.group)|\(resource.name)"
            guard !shadowed.contains(key) || !resources.contains(where: {
                $0.group.isEmpty && $0.name == resource.name && $0.isListable
            }) else { return false }
            return seen.insert(key).inserted
        }
    }

    func resource(kind: String, group: String? = nil) -> APIResource? {
        resources.first { $0.kind == kind && (group == nil || $0.group == group) && $0.isListable }
    }

    func resource(named name: String, group: String) -> APIResource? {
        resources.first { $0.name == name && $0.group == group }
    }

    func resource(forStableKey key: String) -> APIResource? {
        resources.first { $0.stableKey == key }
    }

    /// Resolves an `apiVersion`/`kind` pair, as found on a live object.
    func resource(apiVersion: String, kind: String) -> APIResource? {
        let parts = apiVersion.split(separator: "/", maxSplits: 1).map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.count == 2 ? parts[1] : parts[0]
        return resources.first { $0.group == group && $0.version == version && $0.kind == kind }
            ?? resources.first { $0.group == group && $0.kind == kind }
    }

    func supports(kind: String, group: String = "") -> Bool {
        resource(kind: kind, group: group) != nil
    }
}

enum APIDiscovery {
    /// Loads the resource catalog, preferring the single-request aggregated
    /// discovery endpoint and falling back to the per-group walk on older
    /// servers.
    static func load(client: KubeClient) async throws -> APICatalog {
        if let catalog = try? await loadAggregated(client: client), !catalog.resources.isEmpty {
            return catalog
        }
        return try await loadLegacy(client: client)
    }

    // MARK: Aggregated discovery (Kubernetes 1.27+)

    private static let aggregatedAccept =
        "application/json;g=apidiscovery.k8s.io;v=v2;as=APIGroupDiscoveryList,"
        + "application/json;g=apidiscovery.k8s.io;v=v2beta1;as=APIGroupDiscoveryList,application/json"

    private static func loadAggregated(client: KubeClient) async throws -> APICatalog {
        var catalog = APICatalog()
        for path in ["/api", "/apis"] {
            var request = KubeRequest.get(path)
            request.accept = aggregatedAccept
            let root = try await client.json(request)
            guard root.string(at: "kind") == "APIGroupDiscoveryList" else { return APICatalog() }
            for group in root.array(at: "items") {
                let groupName = group.string(at: "metadata.name") ?? ""
                for version in group.array(at: "versions") {
                    guard let versionName = version.string(at: "version") else { continue }
                    catalog.groupVersions.append(groupName.isEmpty ? versionName : "\(groupName)/\(versionName)")
                    for resource in version.array(at: "resources") {
                        guard let parsed = parseAggregated(resource, group: groupName, version: versionName)
                        else { continue }
                        catalog.resources.append(parsed)
                    }
                }
            }
        }
        return catalog
    }

    private static func parseAggregated(_ value: JSONValue, group: String, version: String) -> APIResource? {
        guard let name = value.string(at: "resource") else { return nil }
        return APIResource(
            group: group,
            version: version,
            name: name,
            singularName: value.string(at: "singularResource") ?? name,
            kind: value.string(at: "responseKind.kind") ?? name.capitalized,
            namespaced: value.string(at: "scope") == "Namespaced",
            verbs: value.array(at: "verbs").compactMap(\.stringValue),
            shortNames: value.array(at: "shortNames").compactMap(\.stringValue),
            categories: value.array(at: "categories").compactMap(\.stringValue),
            subresources: value.array(at: "subresources").compactMap { $0.string(at: "subresource") }
        )
    }

    // MARK: Legacy discovery

    private static func loadLegacy(client: KubeClient) async throws -> APICatalog {
        var groupVersions: [String] = []

        let core = try await client.get(path: "/api")
        for version in core.array(at: "versions").compactMap(\.stringValue) {
            groupVersions.append(version)
        }

        let groups = try await client.get(path: "/apis")
        for group in groups.array(at: "groups") {
            if let preferred = group.string(at: "preferredVersion.groupVersion") {
                groupVersions.append(preferred)
            } else {
                groupVersions.append(contentsOf: group.array(at: "versions").compactMap {
                    $0.string(at: "groupVersion")
                })
            }
        }

        var catalog = APICatalog()
        catalog.groupVersions = groupVersions

        // Discovery of a broken aggregated API server must not fail the others.
        catalog.resources = await withTaskGroup(of: [APIResource].self) { taskGroup in
            for groupVersion in groupVersions {
                taskGroup.addTask {
                    let path = groupVersion.contains("/") ? "/apis/\(groupVersion)" : "/api/\(groupVersion)"
                    guard let list = try? await client.get(path: path) else { return [] }
                    let parts = groupVersion.split(separator: "/", maxSplits: 1).map(String.init)
                    let group = parts.count == 2 ? parts[0] : ""
                    let version = parts.count == 2 ? parts[1] : parts[0]
                    var byName: [String: APIResource] = [:]
                    var subresources: [String: [String]] = [:]
                    for entry in list.array(at: "resources") {
                        guard let name = entry.string(at: "name") else { continue }
                        if let slash = name.firstIndex(of: "/") {
                            let parent = String(name[name.startIndex..<slash])
                            subresources[parent, default: []].append(String(name[name.index(after: slash)...]))
                            continue
                        }
                        byName[name] = APIResource(
                            group: group,
                            version: version,
                            name: name,
                            singularName: entry.string(at: "singularName").flatMap { $0.isEmpty ? nil : $0 } ?? name,
                            kind: entry.string(at: "kind") ?? name.capitalized,
                            namespaced: entry.bool(at: "namespaced") ?? true,
                            verbs: entry.array(at: "verbs").compactMap(\.stringValue),
                            shortNames: entry.array(at: "shortNames").compactMap(\.stringValue),
                            categories: entry.array(at: "categories").compactMap(\.stringValue),
                            subresources: []
                        )
                    }
                    for (parent, children) in subresources {
                        byName[parent]?.subresources = children
                    }
                    return Array(byName.values)
                }
            }
            var all: [APIResource] = []
            for await resources in taskGroup { all.append(contentsOf: resources) }
            return all
        }
        return catalog
    }
}
