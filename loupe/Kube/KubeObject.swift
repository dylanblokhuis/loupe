import Foundation

/// A Kubernetes object held in its unstructured form, with typed accessors for
/// the metadata every kind shares. Keeping the raw JSON means the app can show
/// any resource, including custom ones it has never heard of.
struct KubeObject: Identifiable, Sendable, Hashable {
    var raw: JSONValue

    init(_ raw: JSONValue) {
        self.raw = raw
    }

    var kind: String { raw.string(at: "kind") ?? "" }
    var apiVersion: String { raw.string(at: "apiVersion") ?? "" }
    var name: String { raw.string(at: "metadata.name") ?? "" }
    var namespace: String? { raw.string(at: "metadata.namespace") }
    var uid: String { raw.string(at: "metadata.uid") ?? "" }
    var resourceVersion: String? { raw.string(at: "metadata.resourceVersion") }
    var creationTimestamp: Date? { KubeDate.parse(raw.string(at: "metadata.creationTimestamp")) }
    var deletionTimestamp: Date? { KubeDate.parse(raw.string(at: "metadata.deletionTimestamp")) }
    var isTerminating: Bool { deletionTimestamp != nil }

    var id: String {
        uid.isEmpty ? "\(namespace ?? "-")/\(kind)/\(name)" : uid
    }

    var qualifiedName: String {
        namespace.map { "\($0)/\(name)" } ?? name
    }

    var labels: [(key: String, value: String)] {
        (raw.object(at: "metadata.labels")?.pairs ?? []).map { ($0.key, $0.value.displayString) }
    }

    var annotations: [(key: String, value: String)] {
        (raw.object(at: "metadata.annotations")?.pairs ?? []).map { ($0.key, $0.value.displayString) }
    }

    var ownerReferences: [OwnerReference] {
        raw.array(at: "metadata.ownerReferences").compactMap { value in
            guard let kind = value.string(at: "kind"), let name = value.string(at: "name") else { return nil }
            return OwnerReference(
                kind: kind,
                name: name,
                apiVersion: value.string(at: "apiVersion") ?? "",
                uid: value.string(at: "uid") ?? "",
                controller: value.bool(at: "controller") ?? false
            )
        }
    }

    var conditions: [KubeCondition] {
        raw.array(at: "status.conditions").compactMap { value in
            guard let type = value.string(at: "type") else { return nil }
            return KubeCondition(
                type: type,
                status: value.string(at: "status") ?? "Unknown",
                reason: value.string(at: "reason"),
                message: value.string(at: "message"),
                lastTransitionTime: KubeDate.parse(value.string(at: "lastTransitionTime"))
            )
        }
    }

    func condition(_ type: String) -> KubeCondition? {
        conditions.first { $0.type == type }
    }

    /// The object as the user should see it: server-managed bookkeeping that
    /// only adds noise is stripped, matching what `kubectl edit` hides.
    var presentableYAML: String {
        YAMLEmitter.string(from: raw.removing("metadata.managedFields"))
    }

    /// Decodes the items of a list response, stamping each with the kind the
    /// list implies.
    ///
    /// A `JobList`'s items arrive with no `kind` or `apiVersion` of their own —
    /// only the list carries them — so anything that switches on `kind`, health
    /// rules included, would otherwise see objects of no kind at all.
    static func items(of list: JSONValue) -> [KubeObject] {
        let listKind = list.string(at: "kind") ?? ""
        let kind = listKind.hasSuffix("List") ? String(listKind.dropLast(4)) : ""
        let apiVersion = list.string(at: "apiVersion") ?? ""
        return list.array(at: "items").map { item in
            guard !kind.isEmpty, let fields = item.objectValue, fields["kind"] == nil else {
                return KubeObject(item)
            }
            // Rebuilt rather than appended to so the type stays at the top,
            // where the YAML tab expects it.
            var stamped = JSONObject()
            if !apiVersion.isEmpty { stamped["apiVersion"] = .string(apiVersion) }
            stamped["kind"] = .string(kind)
            for pair in fields.pairs { stamped[pair.key] = pair.value }
            return KubeObject(.object(stamped))
        }
    }

    static func == (lhs: KubeObject, rhs: KubeObject) -> Bool {
        lhs.raw == rhs.raw
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(resourceVersion)
    }
}

struct OwnerReference: Sendable, Hashable {
    var kind: String
    var name: String
    var apiVersion: String
    var uid: String
    var controller: Bool
}

struct KubeCondition: Sendable, Hashable, Identifiable {
    var type: String
    var status: String
    var reason: String?
    var message: String?
    var lastTransitionTime: Date?

    var id: String { type }
    var isTrue: Bool { status == "True" }
}

// MARK: - Health

/// A coarse traffic-light state used for row tinting and sidebar badges.
enum ResourceHealth: Sendable, Hashable {
    case ok
    case warning
    case error
    case pending
    case terminating
    case unknown

    var sortOrder: Int {
        switch self {
        case .error: return 0
        case .warning: return 1
        case .pending: return 2
        case .terminating: return 3
        case .unknown: return 4
        case .ok: return 5
        }
    }
}

extension KubeObject {
    /// Derives health from whichever status fields the kind happens to expose,
    /// falling back to standard conditions for resources with no special rule.
    var health: ResourceHealth {
        if isTerminating { return .terminating }

        switch kind {
        case "Pod":
            return podHealth
        case "Node":
            // A node that is both cordoned and down is down; readiness wins.
            guard let ready = condition("Ready") else { return .unknown }
            if !ready.isTrue { return .error }
            return raw.bool(at: "spec.unschedulable") == true ? .warning : .ok
        case "Deployment", "StatefulSet", "ReplicaSet", "ReplicationController":
            let desired = raw.int(at: "spec.replicas") ?? 0
            let ready = raw.int(at: "status.readyReplicas") ?? 0
            if desired == 0 { return ready == 0 ? .ok : .warning }
            if ready == 0 {
                // No pods created yet is a rollout in progress, not a failure.
                return (raw.int(at: "status.replicas") ?? 0) == 0 ? .pending : .error
            }
            return ready >= desired ? .ok : .warning
        case "DaemonSet":
            let desired = raw.int(at: "status.desiredNumberScheduled") ?? 0
            let ready = raw.int(at: "status.numberReady") ?? 0
            if desired == 0 { return .ok }
            if ready == 0 { return .error }
            return ready >= desired ? .ok : .warning
        case "Job":
            // A job that retried and then succeeded is a success, so the
            // Complete condition is checked before the retry count.
            if condition("Complete")?.isTrue == true { return .ok }
            if condition("Failed")?.isTrue == true { return .error }
            let backoffLimit = raw.int(at: "spec.backoffLimit") ?? 6
            if (raw.int(at: "status.failed") ?? 0) > backoffLimit { return .error }
            if (raw.int(at: "status.active") ?? 0) > 0 { return .pending }
            if (raw.int(at: "status.failed") ?? 0) > 0 { return .warning }
            return .unknown
        case "CronJob":
            return raw.bool(at: "spec.suspend") == true ? .warning : .ok
        case "PersistentVolumeClaim", "PersistentVolume":
            switch raw.string(at: "status.phase") {
            case "Bound", "Available": return .ok
            case "Pending": return .pending
            case "Lost", "Failed": return .error
            case "Released": return .warning
            default: return .unknown
            }
        case "Namespace":
            return raw.string(at: "status.phase") == "Active" ? .ok : .pending
        case "Event":
            switch raw.string(at: "type") {
            case "Warning": return .warning
            case "Normal": return .ok
            default: return .unknown
            }
        case "Service":
            if raw.string(at: "spec.type") == "LoadBalancer",
               raw.array(at: "status.loadBalancer.ingress").isEmpty {
                return .pending
            }
            return .ok
        case "HorizontalPodAutoscaler":
            if condition("ScalingActive")?.status == "False" { return .warning }
            return .ok
        default:
            return genericHealth
        }
    }

    private var podHealth: ResourceHealth {
        let phase = raw.string(at: "status.phase") ?? ""
        let containerStatuses = raw.array(at: "status.containerStatuses")
        let initStatuses = raw.array(at: "status.initContainerStatuses")
        // Init containers stall pods in Pending, so their waiting reasons have
        // to be inspected too — `Init:CrashLoopBackOff` is a failure, not a wait.
        let waitingReasons = (containerStatuses + initStatuses)
            .compactMap { $0.string(at: "state.waiting.reason") }
        let badReasons: Set<String> = [
            "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError",
            "CreateContainerError", "InvalidImageName", "RunContainerError",
        ]
        if waitingReasons.contains(where: { badReasons.contains($0) }) { return .error }
        if initStatuses.contains(where: {
            ($0.int(at: "lastState.terminated.exitCode") ?? 0) != 0 && ($0.int(at: "restartCount") ?? 0) > 2
        }) {
            return .error
        }

        switch phase {
        case "Running":
            let ready = containerStatuses.filter { $0.bool(at: "ready") == true }.count
            if !containerStatuses.isEmpty, ready < containerStatuses.count { return .warning }
            return .ok
        case "Succeeded": return .ok
        case "Pending": return .pending
        case "Failed": return .error
        default: return .unknown
        }
    }

    private var genericHealth: ResourceHealth {
        let conditions = self.conditions
        guard !conditions.isEmpty else { return .unknown }
        for name in ["Ready", "Available", "Established", "Succeeded", "Healthy", "Synced"] {
            if let condition = conditions.first(where: { $0.type == name }) {
                return condition.isTrue ? .ok : .warning
            }
        }
        for name in ["Failed", "Degraded", "Error"] {
            if let condition = conditions.first(where: { $0.type == name }), condition.isTrue {
                return .error
            }
        }
        return .unknown
    }
}

// MARK: - Table rendering

struct ResourceColumn: Sendable, Hashable, Identifiable {
    var name: String
    var type: String
    var format: String
    var priority: Int
    var description: String

    var id: String { name }
    /// Columns the API server marks as `priority > 0` are the `-o wide` extras.
    var isWide: Bool { priority > 0 }
}

struct ResourceRow: Identifiable, Sendable {
    var object: KubeObject
    var cells: [String]
    /// Live usage, stamped on by `ResourceListModel`. The Table response the
    /// columns come from carries no such cell — metrics are a different API
    /// on a refresh cycle of their own — so it is folded into the row rather
    /// than looked up while drawing, which keeps `DisplayColumn.value(for:)`
    /// a pure function of the row for sorting and column sizing alike.
    var usage: ResourceUsage?

    var id: String { object.id }
}

/// What one object is using right now, from metrics-server or Prometheus.
struct ResourceUsage: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case cpu
        case memory

        var title: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            }
        }
    }

    var cpuMillicores: Double
    var memoryBytes: Double

    func value(_ kind: Kind) -> Double {
        switch kind {
        case .cpu: return cpuMillicores
        case .memory: return memoryBytes
        }
    }

    func formatted(_ kind: Kind) -> String {
        switch kind {
        case .cpu: return Quantity.formatCPU(cpuMillicores)
        case .memory: return Quantity.formatBytes(memoryBytes)
        }
    }
}

/// A decoded `meta.k8s.io/v1` Table response.
struct ResourceTable: Sendable {
    var columns: [ResourceColumn] = []
    var rows: [ResourceRow] = []
    var resourceVersion: String?

    static func decode(_ value: JSONValue) -> ResourceTable {
        // Aggregated API servers occasionally ignore the Table accept header and
        // answer with an ordinary List; rendering name and age beats rendering
        // nothing at all.
        if value.string(at: "kind") != "Table", value["items"] != nil {
            return decodeList(value)
        }

        var table = ResourceTable()
        table.resourceVersion = value.string(at: "metadata.resourceVersion")
        table.columns = value.array(at: "columnDefinitions").compactMap { column in
            guard let name = column.string(at: "name") else { return nil }
            return ResourceColumn(
                name: name,
                type: column.string(at: "type") ?? "string",
                format: column.string(at: "format") ?? "",
                priority: column.int(at: "priority") ?? 0,
                description: column.string(at: "description") ?? ""
            )
        }
        table.rows = value.array(at: "rows").compactMap { row in
            guard let object = row["object"], object.objectValue != nil else { return nil }
            return ResourceRow(
                object: KubeObject(object),
                cells: row.array(at: "cells").map(\.displayString)
            )
        }
        return table
    }

    private static func decodeList(_ value: JSONValue) -> ResourceTable {
        var table = ResourceTable()
        table.resourceVersion = value.string(at: "metadata.resourceVersion")
        table.columns = [
            ResourceColumn(name: "Name", type: "string", format: "name", priority: 0, description: ""),
            ResourceColumn(name: "Age", type: "string", format: "", priority: 0, description: ""),
        ]
        // Items in a List carry no kind of their own; the list's own kind is
        // `PodList`, so the element kind is that minus the suffix.
        let listKind = value.string(at: "kind") ?? ""
        let itemKind = listKind.hasSuffix("List") ? String(listKind.dropLast(4)) : listKind
        let apiVersion = value.string(at: "apiVersion") ?? ""

        table.rows = value.array(at: "items").compactMap { item in
            guard var object = item.objectValue else { return nil }
            if object["kind"] == nil, !itemKind.isEmpty {
                var stamped = JSONObject([("kind", .string(itemKind)), ("apiVersion", .string(apiVersion))])
                for (key, child) in object.pairs { stamped[key] = child }
                object = stamped
            }
            let kube = KubeObject(.object(object))
            return ResourceRow(
                object: kube,
                cells: [kube.name, Age.short(since: kube.creationTimestamp)]
            )
        }
        return table
    }
}

// MARK: - Watch

struct WatchEvent: Sendable {
    enum Kind: String, Sendable {
        case added = "ADDED", modified = "MODIFIED", deleted = "DELETED"
        case bookmark = "BOOKMARK", error = "ERROR"
    }

    var type: Kind
    var payload: JSONValue

    static func decode(_ line: String) -> WatchEvent? {
        guard let value = try? JSONParser.parse(line),
              let rawType = value.string(at: "type"),
              let type = Kind(rawValue: rawType),
              let object = value["object"]
        else { return nil }
        return WatchEvent(type: type, payload: object)
    }
}
