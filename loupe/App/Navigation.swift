import Foundation

enum NavDestination: Hashable, Sendable {
    case clusterOverview
    case workloadOverview
    /// Browses any discovered API resource, keyed by `APIResource.stableKey`.
    case resource(String)
    case helmReleases
    case portForwarding

    /// Stable string form so the last-viewed screen survives a relaunch.
    var storageKey: String {
        switch self {
        case .clusterOverview: return "cluster"
        case .workloadOverview: return "workloads"
        case .helmReleases: return "helm"
        case .portForwarding: return "portforward"
        case .resource(let key): return "resource:\(key)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "cluster": self = .clusterOverview
        case "workloads": self = .workloadOverview
        case "helm": self = .helmReleases
        case "portforward": self = .portForwarding
        default:
            guard storageKey.hasPrefix("resource:") else { return nil }
            self = .resource(String(storageKey.dropFirst("resource:".count)))
        }
    }
}

struct NavEntry: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var icon: String
    var destination: NavDestination
}

struct NavGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var icon: String
    var entries: [NavEntry] = []
    var subgroups: [NavGroup] = []

    var isEmpty: Bool { entries.isEmpty && subgroups.allSatisfy(\.isEmpty) }
}

/// Builds the sidebar from live discovery.
///
/// Well-known resources are placed into the familiar categories in a fixed
/// order; everything else — including custom resources the app has never seen —
/// is grouped by API group so nothing in the cluster is unreachable.
enum NavigationCatalog {
    /// (group, plural name) → (category id, sort index)
    private static let placements: [String: (category: String, order: Int)] = {
        var map: [String: (String, Int)] = [:]
        func place(_ category: String, _ entries: [(String, String)]) {
            for (index, entry) in entries.enumerated() {
                map["\(entry.0)|\(entry.1)"] = (category, index)
            }
        }
        place("cluster", [
            ("", "nodes"),
        ])
        place("workloads", [
            ("", "pods"),
            ("apps", "deployments"),
            ("apps", "daemonsets"),
            ("apps", "statefulsets"),
            ("apps", "replicasets"),
            ("", "replicationcontrollers"),
            ("batch", "jobs"),
            ("batch", "cronjobs"),
        ])
        place("config", [
            ("", "configmaps"),
            ("", "secrets"),
            ("", "resourcequotas"),
            ("", "limitranges"),
            ("autoscaling", "horizontalpodautoscalers"),
            ("autoscaling.k8s.io", "verticalpodautoscalers"),
            ("policy", "poddisruptionbudgets"),
            ("scheduling.k8s.io", "priorityclasses"),
            ("node.k8s.io", "runtimeclasses"),
            ("coordination.k8s.io", "leases"),
            ("admissionregistration.k8s.io", "mutatingwebhookconfigurations"),
            ("admissionregistration.k8s.io", "validatingwebhookconfigurations"),
            ("admissionregistration.k8s.io", "validatingadmissionpolicies"),
        ])
        place("network", [
            ("", "services"),
            ("discovery.k8s.io", "endpointslices"),
            ("", "endpoints"),
            ("networking.k8s.io", "ingresses"),
            ("networking.k8s.io", "ingressclasses"),
            ("networking.k8s.io", "networkpolicies"),
            ("gateway.networking.k8s.io", "gateways"),
            ("gateway.networking.k8s.io", "httproutes"),
            ("gateway.networking.k8s.io", "gatewayclasses"),
        ])
        place("storage", [
            ("", "persistentvolumeclaims"),
            ("", "persistentvolumes"),
            ("storage.k8s.io", "storageclasses"),
            ("storage.k8s.io", "csidrivers"),
            ("storage.k8s.io", "csinodes"),
            ("storage.k8s.io", "volumeattachments"),
            ("snapshot.storage.k8s.io", "volumesnapshots"),
            ("snapshot.storage.k8s.io", "volumesnapshotclasses"),
        ])
        place("access", [
            ("", "serviceaccounts"),
            ("rbac.authorization.k8s.io", "roles"),
            ("rbac.authorization.k8s.io", "rolebindings"),
            ("rbac.authorization.k8s.io", "clusterroles"),
            ("rbac.authorization.k8s.io", "clusterrolebindings"),
        ])
        place("namespaces", [
            ("", "namespaces"),
        ])
        place("events", [
            ("", "events"),
        ])
        return map
    }()

    private static let categories: [(id: String, title: String, icon: String)] = [
        ("cluster", "Cluster", "server.rack"),
        ("namespaces", "Namespaces", "square.stack.3d.up"),
        ("workloads", "Workloads", "shippingbox"),
        ("config", "Config", "slider.horizontal.3"),
        ("network", "Network", "network"),
        ("storage", "Storage", "externaldrive"),
        ("helm", "Helm", "sailboat"),
        ("access", "Access Control", "lock.shield"),
        ("events", "Events", "bell"),
    ]

    static let iconsByKind: [String: String] = [
        "Node": "cpu",
        "Pod": "cube",
        "Deployment": "square.stack.3d.up.fill",
        "DaemonSet": "square.grid.3x3.fill",
        "StatefulSet": "cylinder.split.1x2",
        "ReplicaSet": "square.on.square",
        "ReplicationController": "square.on.square",
        "Job": "hammer",
        "CronJob": "clock.arrow.circlepath",
        "ConfigMap": "doc.plaintext",
        "Secret": "key",
        "ResourceQuota": "gauge.with.dots.needle.33percent",
        "LimitRange": "arrow.up.arrow.down.square",
        "HorizontalPodAutoscaler": "arrow.up.left.and.arrow.down.right",
        "PodDisruptionBudget": "shield.lefthalf.filled",
        "PriorityClass": "arrow.up.to.line",
        "RuntimeClass": "gearshape.2",
        "Lease": "signature",
        "Service": "point.3.connected.trianglepath.dotted",
        "Endpoints": "point.topleft.down.to.point.bottomright.curvepath",
        "EndpointSlice": "point.topleft.down.to.point.bottomright.curvepath",
        "Ingress": "arrow.right.to.line",
        "IngressClass": "arrow.right.to.line.compact",
        "NetworkPolicy": "shield.checkered",
        "PersistentVolumeClaim": "externaldrive.badge.plus",
        "PersistentVolume": "externaldrive.fill",
        "StorageClass": "externaldrive.badge.timemachine",
        "Namespace": "square.stack.3d.up",
        "Event": "bell",
        "ServiceAccount": "person.badge.key",
        "Role": "person.text.rectangle",
        "RoleBinding": "link",
        "ClusterRole": "person.text.rectangle.fill",
        "ClusterRoleBinding": "link.circle",
        "CustomResourceDefinition": "puzzlepiece.extension",
    ]

    static func icon(for resource: APIResource) -> String {
        iconsByKind[resource.kind] ?? "circle.grid.2x2"
    }

    static func build(catalog: APICatalog, includeHelm: Bool) -> [NavGroup] {
        var buckets: [String: [(order: Int, entry: NavEntry)]] = [:]
        var customByGroup: [String: [NavEntry]] = [:]

        for resource in catalog.browsable {
            let entry = NavEntry(
                id: resource.stableKey,
                title: resource.displayName,
                icon: icon(for: resource),
                destination: .resource(resource.stableKey)
            )
            if let placement = placements["\(resource.group)|\(resource.name)"] {
                buckets[placement.category, default: []].append((placement.order, entry))
            } else {
                customByGroup[resource.group.isEmpty ? "core" : resource.group, default: []].append(entry)
            }
        }

        var groups: [NavGroup] = []
        for category in categories {
            var group = NavGroup(id: category.id, title: category.title, icon: category.icon)
            switch category.id {
            case "cluster":
                group.entries.append(NavEntry(
                    id: "cluster.overview", title: "Overview",
                    icon: "chart.pie", destination: .clusterOverview
                ))
            case "workloads":
                group.entries.append(NavEntry(
                    id: "workloads.overview", title: "Overview",
                    icon: "chart.bar.doc.horizontal", destination: .workloadOverview
                ))
            case "network":
                group.entries.append(NavEntry(
                    id: "network.portforward", title: "Port Forwarding",
                    icon: "arrow.left.arrow.right", destination: .portForwarding
                ))
            case "helm":
                guard includeHelm else { continue }
                group.entries.append(NavEntry(
                    id: "helm.releases", title: "Releases",
                    icon: "shippingbox.and.arrow.backward", destination: .helmReleases
                ))
            default:
                break
            }
            group.entries.append(contentsOf: (buckets[category.id] ?? [])
                .sorted { $0.order < $1.order }
                .map(\.entry))
            if !group.isEmpty { groups.append(group) }
        }

        if !customByGroup.isEmpty {
            var custom = NavGroup(
                id: "custom", title: "Custom Resources", icon: "puzzlepiece.extension"
            )
            custom.subgroups = customByGroup.keys.sorted().map { groupName in
                NavGroup(
                    id: "custom.\(groupName)",
                    title: groupName,
                    icon: "folder",
                    entries: (customByGroup[groupName] ?? []).sorted { $0.title < $1.title }
                )
            }
            groups.append(custom)
        }
        return groups
    }
}
