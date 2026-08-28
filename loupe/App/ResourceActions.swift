import AppKit
import Foundation
import Observation

/// Mutating operations the UI can perform on a resource.
///
/// Everything generic (delete, edit) works for any kind; the rest are the
/// kind-specific conveniences that make the app more than a YAML viewer.
enum ResourceActions {
    static func delete(
        client: KubeClient, resource: APIResource, object: KubeObject, propagation: String = "Background"
    ) async throws {
        try await client.delete(
            path: resource.itemPath(namespace: object.namespace, name: object.name),
            propagationPolicy: propagation
        )
    }

    static func replace(
        client: KubeClient, resource: APIResource, object: KubeObject, yaml: String
    ) async throws -> KubeObject {
        let parsed = try YAMLParser.parse(yaml)
        guard parsed.objectValue != nil else {
            throw ActionError.message("The document is not a Kubernetes object.")
        }
        let updated = try await client.replace(
            path: resource.itemPath(namespace: object.namespace, name: object.name),
            object: parsed
        )
        return KubeObject(updated)
    }

    static func scale(
        client: KubeClient, resource: APIResource, object: KubeObject, replicas: Int
    ) async throws {
        let patch = JSONValue.object(JSONObject([("spec", .object(JSONObject([("replicas", .int(replicas))])))]))
        _ = try await client.patch(
            path: resource.itemPath(namespace: object.namespace, name: object.name) + "/scale",
            patch: patch
        )
    }

    /// Mirrors `kubectl rollout restart`: stamps the pod template so the
    /// controller rolls out fresh pods.
    static func restart(client: KubeClient, resource: APIResource, object: KubeObject) async throws {
        let patch = JSONValue.object(JSONObject([
            ("spec", .object(JSONObject([
                ("template", .object(JSONObject([
                    ("metadata", .object(JSONObject([
                        ("annotations", .object(JSONObject([
                            ("kubectl.kubernetes.io/restartedAt", .string(KubeDate.format(Date()))),
                        ]))),
                    ]))),
                ]))),
            ]))),
        ]))
        _ = try await client.patch(
            path: resource.itemPath(namespace: object.namespace, name: object.name),
            patch: patch,
            type: .strategicMerge
        )
    }

    static func setSuspended(
        client: KubeClient, resource: APIResource, object: KubeObject, suspended: Bool
    ) async throws {
        let patch = JSONValue.object(JSONObject([("spec", .object(JSONObject([("suspend", .bool(suspended))])))]))
        _ = try await client.patch(
            path: resource.itemPath(namespace: object.namespace, name: object.name), patch: patch
        )
    }

    static func setCordoned(
        client: KubeClient, resource: APIResource, object: KubeObject, cordoned: Bool
    ) async throws {
        let patch = JSONValue.object(JSONObject([
            ("spec", .object(JSONObject([("unschedulable", .bool(cordoned))]))),
        ]))
        _ = try await client.patch(
            path: resource.itemPath(namespace: nil, name: object.name), patch: patch
        )
    }

    struct DrainSummary: Sendable {
        var evicted = 0
        var skipped = 0
        var failures: [String] = []

        var describes: String {
            var parts = ["evicted \(evicted)"]
            if skipped > 0 { parts.append("skipped \(skipped)") }
            if !failures.isEmpty { parts.append("\(failures.count) refused") }
            return parts.joined(separator: ", ")
        }
    }

    /// Cordons the node and evicts the pods `kubectl drain` would evict.
    ///
    /// DaemonSet pods, static (mirror) pods and pods that have already finished
    /// are left alone, and — unlike a naive loop — an eviction the API server
    /// refuses is reported rather than counted as a success. A PodDisruption
    /// Budget rejection is the case that matters: silently claiming a node was
    /// drained when it was not is how people take unplanned outages.
    static func drain(
        client: KubeClient, resource: APIResource, object: KubeObject
    ) async throws -> DrainSummary {
        try await setCordoned(client: client, resource: resource, object: object, cordoned: true)
        let pods = try await client.get(
            path: "/api/v1/pods",
            query: [URLQueryItem(name: "fieldSelector", value: "spec.nodeName=\(object.name)")]
        )

        var summary = DrainSummary()
        for item in pods.array(at: "items") {
            let pod = KubeObject(item)
            let namespace = pod.namespace ?? "default"
            let phase = pod.raw.string(at: "status.phase") ?? ""

            let isDaemonSetPod = pod.ownerReferences.contains { $0.kind == "DaemonSet" }
            let isMirrorPod = pod.raw.value(at: "metadata.annotations.kubernetes\\.io/config\\.mirror") != nil
                || pod.annotations.contains { $0.key == "kubernetes.io/config.mirror" }
            let isFinished = phase == "Succeeded" || phase == "Failed"
            let isUnmanaged = pod.ownerReferences.isEmpty

            if isDaemonSetPod || isMirrorPod || isFinished || isUnmanaged {
                summary.skipped += 1
                continue
            }

            let eviction = JSONValue.object(JSONObject([
                ("apiVersion", .string("policy/v1")),
                ("kind", .string("Eviction")),
                ("metadata", .object(JSONObject([
                    ("name", .string(pod.name)),
                    ("namespace", .string(namespace)),
                ]))),
            ]))
            do {
                _ = try await client.create(
                    path: "/api/v1/namespaces/\(namespace)/pods/\(pod.name)/eviction",
                    object: eviction
                )
                summary.evicted += 1
            } catch let error as KubeStatusError where error.isNotFound {
                summary.skipped += 1
            } catch {
                summary.failures.append("\(namespace)/\(pod.name): \(ClusterConnection.describe(error))")
            }
        }
        return summary
    }

    /// Creates a one-off Job from a CronJob, as `kubectl create job --from` does.
    static func triggerCronJob(client: KubeClient, object: KubeObject) async throws -> String {
        guard let template = object.raw.value(at: "spec.jobTemplate"),
              let spec = template.value(at: "spec")
        else {
            throw ActionError.message("This CronJob has no job template.")
        }
        let suffix = String(Int(Date().timeIntervalSince1970) % 1_000_000)
        // Job names are DNS-1123 labels: lowercase alphanumerics and dashes,
        // never leading or trailing, at most 63 characters.
        let stem = object.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .prefix(52 - suffix.count - 8)
        let name = stem.drop(while: { $0 == "-" })
            .reversed().drop(while: { $0 == "-" }).reversed()
            .reduce(into: "") { $0.append($1) } + "-manual-" + suffix
        var metadata = JSONObject([
            ("name", .string(name)),
            ("namespace", .string(object.namespace ?? "default")),
        ])
        var annotations = template.object(at: "metadata.annotations") ?? JSONObject()
        annotations["cronjob.kubernetes.io/instantiate"] = .string("loupe")
        metadata["annotations"] = .object(annotations)
        if let labels = template.object(at: "metadata.labels") { metadata["labels"] = .object(labels) }

        let job = JSONValue.object(JSONObject([
            ("apiVersion", .string("batch/v1")),
            ("kind", .string("Job")),
            ("metadata", .object(metadata)),
            ("spec", spec),
        ]))
        let created = try await client.create(
            path: "/apis/batch/v1/namespaces/\(object.namespace ?? "default")/jobs", object: job
        )
        return created.string(at: "metadata.name") ?? name
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum ActionError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Runs actions and surfaces failures without every call site repeating the
/// same do/catch and alert plumbing.
@MainActor
@Observable
final class ActionRunner {
    var errorMessage: String?
    var statusMessage: String?
    var isBusy = false

    func run(_ describe: String, _ operation: @escaping () async throws -> String?) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await operation()
                statusMessage = result ?? describe
                try? await Task.sleep(for: .seconds(4))
                if statusMessage == (result ?? describe) { statusMessage = nil }
            } catch {
                errorMessage = ClusterConnection.describe(error)
            }
        }
    }
}
