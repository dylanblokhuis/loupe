import Foundation

/// Resolves the pods a controller currently owns.
///
/// This is what makes "show me the logs for the whole Deployment" possible: the
/// log endpoint only ever speaks about one pod, so the fan-out has to happen
/// here.
enum WorkloadPods {
    /// Controllers whose pods the app can gather. A ReplicaSet is included
    /// because it is what a Deployment's rollout history is made of.
    static let kinds: Set<String> = [
        "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet",
        "ReplicationController", "Job", "CronJob",
    ]

    static func supports(_ object: KubeObject) -> Bool {
        kinds.contains(object.kind) && object.namespace != nil
    }

    /// The controller's selector as a `labelSelector` query value, or `nil`
    /// when the kind has none (a CronJob) or it is empty.
    ///
    /// A Deployment's selector also matches pods left over from previous
    /// ReplicaSets, which is the right answer here: during a rollout you want
    /// the old pods' logs too.
    static func selectorExpression(for object: KubeObject) -> String? {
        guard let selector = object.raw.object(at: "spec.selector") else { return nil }
        var terms: [String] = []
        // A ReplicationController's selector is a plain label map; every other
        // controller uses a LabelSelector. Telling them apart by shape rather
        // than by `kind` keeps this working on objects that arrived as list
        // items, which carry no `kind` at all.
        if selector["matchLabels"] == nil, selector["matchExpressions"] == nil {
            terms = selector.pairs.map { "\($0.key)=\($0.value.displayString)" }
        } else {
            terms = (object.raw.object(at: "spec.selector.matchLabels")?.pairs ?? [])
                .map { "\($0.key)=\($0.value.displayString)" }
            for expression in object.raw.array(at: "spec.selector.matchExpressions") {
                guard let key = expression.string(at: "key"),
                      let op = expression.string(at: "operator") else { continue }
                let values = expression.array(at: "values").compactMap(\.stringValue).joined(separator: ",")
                switch op {
                case "In": terms.append("\(key) in (\(values))")
                case "NotIn": terms.append("\(key) notin (\(values))")
                case "Exists": terms.append(key)
                case "DoesNotExist": terms.append("!\(key)")
                default: continue
                }
            }
        }
        return terms.isEmpty ? nil : terms.joined(separator: ",")
    }

    /// Pods belonging to the controller, newest first — a rollout's fresh pods
    /// are the ones you usually came to read.
    static func resolve(client: KubeClient, workload: KubeObject) async throws -> [KubeObject] {
        guard let namespace = workload.namespace else { return [] }
        if workload.raw.value(at: "spec.jobTemplate") != nil {
            return try await cronJobPods(client: client, cronJob: workload, namespace: namespace)
        }
        guard let expression = selectorExpression(for: workload) else { return [] }
        let list = try await client.get(
            path: "/api/v1/namespaces/\(namespace)/pods",
            query: [
                URLQueryItem(name: "labelSelector", value: expression),
                URLQueryItem(name: "limit", value: "500"),
            ]
        )
        return sorted(KubeObject.items(of: list))
    }

    /// A CronJob has no selector of its own, so its pods are reached through
    /// the Jobs it created. Ownership is checked by UID rather than by the
    /// `job-name` label, which is the only way that stays correct when a Job of
    /// the same name has been recreated.
    private static func cronJobPods(
        client: KubeClient, cronJob: KubeObject, namespace: String
    ) async throws -> [KubeObject] {
        let jobUIDs = Set(try await jobs(client: client, cronJob: cronJob, namespace: namespace).map(\.uid))
        guard !jobUIDs.isEmpty else { return [] }
        let pods = try await client.get(
            path: "/api/v1/namespaces/\(namespace)/pods",
            query: [URLQueryItem(name: "limit", value: "1000")]
        )
        return sorted(KubeObject.items(of: pods).filter { pod in
            pod.ownerReferences.contains { $0.kind == "Job" && jobUIDs.contains($0.uid) }
        })
    }

    /// The Jobs a CronJob has created, newest first.
    static func jobs(client: KubeClient, cronJob: KubeObject, namespace: String) async throws -> [KubeObject] {
        let list = try await client.get(
            path: "/apis/batch/v1/namespaces/\(namespace)/jobs",
            query: [URLQueryItem(name: "limit", value: "500")]
        )
        return sorted(KubeObject.items(of: list).filter { job in
            job.ownerReferences.contains { $0.kind == "CronJob" && $0.uid == cronJob.uid }
        })
    }

    private static func sorted(_ objects: [KubeObject]) -> [KubeObject] {
        objects.sorted {
            let left = $0.creationTimestamp ?? .distantPast
            let right = $1.creationTimestamp ?? .distantPast
            if left != right { return left > right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Container names from a pod spec or from a controller's pod template, so
    /// a log viewer can offer them before any pod has been fetched.
    ///
    /// The template is located by shape rather than by `kind`: objects that
    /// arrive as items of a list carry no `kind` at all.
    static func templateContainers(of object: KubeObject) -> [String] {
        guard let spec = object.raw.value(at: "spec.jobTemplate.spec.template.spec")
            ?? object.raw.value(at: "spec.template.spec")
            ?? object.raw.value(at: "spec")
        else { return [] }
        return spec.array(at: "containers").compactMap { $0.string(at: "name") }
            + spec.array(at: "initContainers").compactMap { $0.string(at: "name") }
    }
}
