import SwiftUI

// MARK: - Pod

struct PodSections: View {
    let connection: ClusterConnection
    let pod: KubeObject

    private var metrics: PodMetrics? {
        connection.podMetrics["\(pod.namespace ?? "")/\(pod.name)"]
    }

    var body: some View {
        DetailSection(title: "Pod", systemImage: "cube") {
            DetailRow("Status", pod.raw.string(at: "status.phase") ?? "—")
            DetailRow("Node", pod.raw.string(at: "spec.nodeName") ?? "—")
            DetailRow("Pod IP", pod.raw.string(at: "status.podIP") ?? "—")
            DetailRow("Host IP", pod.raw.string(at: "status.hostIP") ?? "—")
            DetailRow("QoS Class", pod.raw.string(at: "status.qosClass") ?? "—")
            DetailRow("Service Account", pod.raw.string(at: "spec.serviceAccountName") ?? "default")
            DetailRow("Restart Policy", pod.raw.string(at: "spec.restartPolicy") ?? "—")
            if let priority = pod.raw.string(at: "spec.priorityClassName") {
                DetailRow("Priority Class", priority)
            }
            if let started = KubeDate.parse(pod.raw.string(at: "status.startTime")) {
                DetailRow("Started", Age.absolute(started))
            }
            if let metrics {
                DetailRow("CPU", Quantity.formatCPU(metrics.cpuMillicores))
                DetailRow("Memory", Quantity.formatBytes(metrics.memoryBytes))
            }
        }

        let initContainers = pod.raw.array(at: "spec.initContainers")
        if !initContainers.isEmpty {
            DetailSection(title: "Init Containers", systemImage: "arrow.down.circle") {
                ForEach(Array(initContainers.enumerated()), id: \.offset) { _, container in
                    ContainerCard(
                        container: container,
                        status: status(for: container, in: "status.initContainerStatuses"),
                        usage: usage(for: container)
                    )
                }
            }
        }

        DetailSection(title: "Containers", systemImage: "shippingbox") {
            ForEach(Array(pod.raw.array(at: "spec.containers").enumerated()), id: \.offset) { _, container in
                ContainerCard(
                    container: container,
                    status: status(for: container, in: "status.containerStatuses"),
                    usage: usage(for: container)
                )
            }
        }

        let volumes = pod.raw.array(at: "spec.volumes")
        if !volumes.isEmpty {
            DetailSection(title: "Volumes", systemImage: "externaldrive") {
                ForEach(Array(volumes.enumerated()), id: \.offset) { _, volume in
                    DetailRow(label: volume.string(at: "name") ?? "—") {
                        Text(Self.volumeSummary(volume)).foregroundStyle(.secondary)
                    }
                }
            }
        }

        let tolerations = pod.raw.array(at: "spec.tolerations")
        if !tolerations.isEmpty {
            DetailSection(title: "Tolerations", systemImage: "hand.raised") {
                FlowLayout(spacing: 4) {
                    ForEach(Array(tolerations.enumerated()), id: \.offset) { _, toleration in
                        Chip(text: Self.tolerationSummary(toleration), color: .secondary)
                    }
                }
            }
        }
    }

    private func status(for container: JSONValue, in path: String) -> JSONValue? {
        guard let name = container.string(at: "name") else { return nil }
        return pod.raw.array(at: path).first { $0.string(at: "name") == name }
    }

    private func usage(for container: JSONValue) -> (Double, Double)? {
        guard let name = container.string(at: "name") else { return nil }
        return metrics?.containers[name]
    }

    static func volumeSummary(_ volume: JSONValue) -> String {
        guard let object = volume.objectValue else { return "—" }
        for key in object.keys where key != "name" {
            let value = object[key] ?? .null
            switch key {
            case "configMap": return "ConfigMap: \(value.string(at: "name") ?? "?")"
            case "secret": return "Secret: \(value.string(at: "secretName") ?? "?")"
            case "persistentVolumeClaim": return "PVC: \(value.string(at: "claimName") ?? "?")"
            case "hostPath": return "HostPath: \(value.string(at: "path") ?? "?")"
            case "emptyDir": return "EmptyDir"
            case "projected": return "Projected (\(value.array(at: "sources").count) sources)"
            default: return key
            }
        }
        return "—"
    }

    static func tolerationSummary(_ toleration: JSONValue) -> String {
        let key = toleration.string(at: "key") ?? "*"
        let effect = toleration.string(at: "effect") ?? "All"
        if let value = toleration.string(at: "value") { return "\(key)=\(value):\(effect)" }
        return "\(key):\(effect)"
    }
}

/// One container inside a pod: image, state, restarts, resources, probes, mounts.
struct ContainerCard: View {
    let container: JSONValue
    let status: JSONValue?
    var usage: (Double, Double)?
    @State private var expanded = false

    private var stateName: String {
        guard let state = status?["state"]?.objectValue, let key = state.keys.first else { return "Waiting" }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    private var stateDetail: String? {
        guard let state = status?["state"]?.objectValue, let key = state.keys.first else { return nil }
        let payload = state[key] ?? .null
        if let reason = payload.string(at: "reason") { return reason }
        if let started = KubeDate.parse(payload.string(at: "startedAt")) {
            return "since \(Age.short(since: started))"
        }
        return nil
    }

    private var stateColor: Color {
        switch stateName {
        case "Running": return status?.bool(at: "ready") == true ? .green : .orange
        case "Terminated":
            return (status?.int(at: "state.terminated.exitCode") ?? 0) == 0 ? .secondary : .red
        default: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 7, height: 7)
                Text(container.string(at: "name") ?? "—")
                    .font(.system(size: 11.5, weight: .semibold))
                Chip(text: stateName, color: stateColor)
                if let detail = stateDetail { Chip(text: detail, color: .secondary) }
                Spacer()
                if let restarts = status?.int(at: "restartCount"), restarts > 0 {
                    Chip(text: "\(restarts) restarts", color: restarts > 5 ? .red : .orange,
                         systemImage: "arrow.clockwise")
                }
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(container.string(at: "image") ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let usage {
                HStack(spacing: 10) {
                    Label(Quantity.formatCPU(usage.0), systemImage: "cpu")
                    Label(Quantity.formatBytes(usage.1), systemImage: "memorychip")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    let ports = container.array(at: "ports")
                    if !ports.isEmpty {
                        DetailRow(label: "Ports") {
                            Text(ports.map {
                                let port = $0.int(at: "containerPort").map(String.init) ?? "?"
                                let proto = $0.string(at: "protocol") ?? "TCP"
                                return "\(port)/\(proto)"
                            }.joined(separator: ", "))
                        }
                    }
                    if let requests = container.object(at: "resources.requests"), !requests.isEmpty {
                        DetailRow("Requests", requests.pairs.map { "\($0.key): \($0.value.displayString)" }
                            .joined(separator: ", "))
                    }
                    if let limits = container.object(at: "resources.limits"), !limits.isEmpty {
                        DetailRow("Limits", limits.pairs.map { "\($0.key): \($0.value.displayString)" }
                            .joined(separator: ", "))
                    }
                    ForEach(["livenessProbe", "readinessProbe", "startupProbe"], id: \.self) { probe in
                        if let value = container[probe], !value.isNull {
                            DetailRow(probe.replacingOccurrences(of: "Probe", with: "").capitalized,
                                      Self.probeSummary(value))
                        }
                    }
                    let mounts = container.array(at: "volumeMounts")
                    if !mounts.isEmpty {
                        DetailRow(label: "Mounts") {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                                    Text("\(mount.string(at: "name") ?? "?") → "
                                         + "\(mount.string(at: "mountPath") ?? "?")"
                                         + ((mount.bool(at: "readOnly") ?? false) ? " (ro)" : ""))
                                        .font(.system(size: 10, design: .monospaced))
                                }
                            }
                        }
                    }
                    let env = container.array(at: "env")
                    if !env.isEmpty {
                        DetailRow(label: "Environment") {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(env.enumerated()), id: \.offset) { _, variable in
                                    Text(Self.envSummary(variable))
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                    if let lastState = status?["lastState"]?.objectValue, !lastState.isEmpty,
                       let key = lastState.keys.first {
                        let payload = lastState[key] ?? .null
                        DetailRow("Last state",
                                  "\(key): \(payload.string(at: "reason") ?? "—")"
                                  + (payload.int(at: "exitCode").map { " (exit \($0))" } ?? ""))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 2)
    }

    static func probeSummary(_ probe: JSONValue) -> String {
        var parts: [String] = []
        if let http = probe["httpGet"] {
            parts.append("http-get \(http.string(at: "path") ?? "/"):"
                         + "\(http["port"]?.displayString ?? "?")")
        } else if let tcp = probe["tcpSocket"] {
            parts.append("tcp \(tcp["port"]?.displayString ?? "?")")
        } else if let exec = probe["exec"] {
            parts.append("exec " + exec.array(at: "command").map(\.displayString).joined(separator: " "))
        }
        if let delay = probe.int(at: "initialDelaySeconds") { parts.append("delay=\(delay)s") }
        if let period = probe.int(at: "periodSeconds") { parts.append("period=\(period)s") }
        if let failure = probe.int(at: "failureThreshold") { parts.append("failures=\(failure)") }
        return parts.joined(separator: " ")
    }

    static func envSummary(_ variable: JSONValue) -> String {
        let name = variable.string(at: "name") ?? "?"
        if let value = variable.string(at: "value") { return "\(name)=\(value)" }
        if let ref = variable.value(at: "valueFrom.secretKeyRef") {
            return "\(name)=<secret \(ref.string(at: "name") ?? "?")/\(ref.string(at: "key") ?? "?")>"
        }
        if let ref = variable.value(at: "valueFrom.configMapKeyRef") {
            return "\(name)=<configmap \(ref.string(at: "name") ?? "?")/\(ref.string(at: "key") ?? "?")>"
        }
        if let ref = variable.string(at: "valueFrom.fieldRef.fieldPath") {
            return "\(name)=<field \(ref)>"
        }
        return "\(name)=<computed>"
    }
}

// MARK: - Node

struct NodeSections: View {
    let connection: ClusterConnection
    let node: KubeObject

    private var metrics: NodeMetrics? { connection.nodeMetrics[node.name] }

    private var allocatableCPU: Double { Quantity.millicores(node.raw.string(at: "status.allocatable.cpu")) }
    private var allocatableMemory: Double { Quantity.bytes(node.raw.string(at: "status.allocatable.memory")) }

    var body: some View {
        DetailSection(title: "Node", systemImage: "cpu") {
            DetailRow("Roles", NodeSections.roles(of: node).joined(separator: ", "))
            DetailRow("Schedulable", (node.raw.bool(at: "spec.unschedulable") ?? false) ? "No (cordoned)" : "Yes")
            DetailRow("Pod CIDR", node.raw.string(at: "spec.podCIDR") ?? "—")
            DetailRow("Provider ID", node.raw.string(at: "spec.providerID") ?? "—")
            ForEach(Array(node.raw.array(at: "status.addresses").enumerated()), id: \.offset) { _, address in
                DetailRow(address.string(at: "type") ?? "Address", address.string(at: "address") ?? "—")
            }
        }

        DetailSection(title: "Capacity", systemImage: "gauge.with.dots.needle.50percent") {
            if let metrics {
                DetailRow(label: "CPU") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Quantity.formatCPU(metrics.cpuMillicores)) of "
                             + "\(Quantity.formatCPU(allocatableCPU))")
                        UsageBar(value: metrics.cpuMillicores, total: allocatableCPU)
                    }
                }
                DetailRow(label: "Memory") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Quantity.formatBytes(metrics.memoryBytes)) of "
                             + "\(Quantity.formatBytes(allocatableMemory))")
                        UsageBar(value: metrics.memoryBytes, total: allocatableMemory, tint: .purple)
                    }
                }
            }
            // Extended resources are domain-prefixed (`nvidia.com/gpu`), so the
            // allocatable side has to be looked up by key rather than by a
            // dotted path, which would split on the dot in the domain.
            ForEach(node.raw.object(at: "status.capacity")?.pairs ?? [], id: \.key) { entry in
                DetailRow(
                    entry.key,
                    "\(entry.value.displayString) capacity · "
                    + "\(node.raw.object(at: "status.allocatable")?[entry.key]?.displayString ?? "—") allocatable"
                )
            }
        }

        let taints = node.raw.array(at: "spec.taints")
        if !taints.isEmpty {
            DetailSection(title: "Taints", systemImage: "exclamationmark.shield") {
                FlowLayout(spacing: 4) {
                    ForEach(Array(taints.enumerated()), id: \.offset) { _, taint in
                        Chip(
                            text: "\(taint.string(at: "key") ?? "?")"
                                + (taint.string(at: "value").map { "=\($0)" } ?? "")
                                + ":\(taint.string(at: "effect") ?? "?")",
                            color: .orange
                        )
                    }
                }
            }
        }

        DetailSection(title: "System Info", systemImage: "info.square") {
            ForEach(node.raw.object(at: "status.nodeInfo")?.pairs ?? [], id: \.key) { entry in
                DetailRow(NodeSections.humanize(entry.key), entry.value.displayString)
            }
        }
    }

    static func roles(of node: KubeObject) -> [String] {
        let roles = node.labels.compactMap { label -> String? in
            if label.key.hasPrefix("node-role.kubernetes.io/") {
                return String(label.key.dropFirst("node-role.kubernetes.io/".count))
            }
            if label.key == "kubernetes.io/role" { return label.value }
            return nil
        }.filter { !$0.isEmpty }
        return roles.isEmpty ? ["<none>"] : roles.sorted()
    }

    static func humanize(_ key: String) -> String {
        var out = ""
        for character in key {
            if character.isUppercase, !out.isEmpty { out += " " }
            out.append(character)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

// MARK: - Service

struct ServiceSections: View {
    let connection: ClusterConnection
    let service: KubeObject
    @State private var endpoints: [String] = []

    var body: some View {
        DetailSection(title: "Service", systemImage: "point.3.connected.trianglepath.dotted") {
            DetailRow("Type", service.raw.string(at: "spec.type") ?? "ClusterIP")
            DetailRow("Cluster IP", service.raw.string(at: "spec.clusterIP") ?? "—")
            let externals = service.raw.array(at: "status.loadBalancer.ingress").compactMap {
                $0.string(at: "ip") ?? $0.string(at: "hostname")
            }
            if !externals.isEmpty { DetailRow("External", externals.joined(separator: ", ")) }
            DetailRow("Session Affinity", service.raw.string(at: "spec.sessionAffinity") ?? "None")
            DetailRow(label: "Ports") {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(service.raw.array(at: "spec.ports").enumerated()), id: \.offset) { _, port in
                        Text("\(port.string(at: "name") ?? "port"): \(port["port"]?.displayString ?? "?")"
                             + " → \(port["targetPort"]?.displayString ?? "?")"
                             + "/\(port.string(at: "protocol") ?? "TCP")"
                             + (port.int(at: "nodePort").map { " (node \($0))" } ?? ""))
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                }
            }
            if let selector = service.raw.object(at: "spec.selector"), !selector.isEmpty {
                DetailRow(label: "Selector") {
                    FlowLayout(spacing: 4) {
                        ForEach(selector.pairs, id: \.key) { entry in
                            Chip(text: "\(entry.key)=\(entry.value.displayString)", color: .accentColor)
                        }
                    }
                }
            }
        }

        DetailSection(title: "Endpoints", systemImage: "arrow.triangle.branch") {
            if endpoints.isEmpty {
                Text("No ready endpoints").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(endpoints, id: \.self) { endpoint in
                        Chip(text: endpoint, color: .green)
                    }
                }
            }
        }
        .task(id: service.id) { await loadEndpoints() }
    }

    private func loadEndpoints() async {
        guard let client = connection.client, let namespace = service.namespace else { return }
        guard let result = try? await client.get(
            path: "/api/v1/namespaces/\(namespace)/endpoints/\(service.name)"
        ) else {
            endpoints = []
            return
        }
        var addresses: [String] = []
        for subset in result.array(at: "subsets") {
            let ports = subset.array(at: "ports").compactMap { $0.int(at: "port") }
            for address in subset.array(at: "addresses") {
                guard let ip = address.string(at: "ip") else { continue }
                if ports.isEmpty {
                    addresses.append(ip)
                } else {
                    addresses.append(contentsOf: ports.map { "\(ip):\($0)" })
                }
            }
        }
        endpoints = addresses
    }
}

// MARK: - Workloads

struct WorkloadSections: View {
    let connection: ClusterConnection
    let workload: KubeObject

    var body: some View {
        DetailSection(title: workload.kind, systemImage: "square.stack.3d.up") {
            if workload.kind == "DaemonSet" {
                DetailRow("Desired", "\(workload.raw.int(at: "status.desiredNumberScheduled") ?? 0)")
                DetailRow("Current", "\(workload.raw.int(at: "status.currentNumberScheduled") ?? 0)")
                DetailRow("Ready", "\(workload.raw.int(at: "status.numberReady") ?? 0)")
                DetailRow("Up to date", "\(workload.raw.int(at: "status.updatedNumberScheduled") ?? 0)")
            } else {
                DetailRow("Replicas",
                          "\(workload.raw.int(at: "status.readyReplicas") ?? 0) ready · "
                          + "\(workload.raw.int(at: "status.replicas") ?? 0) current · "
                          + "\(workload.raw.int(at: "spec.replicas") ?? 0) desired")
                if let updated = workload.raw.int(at: "status.updatedReplicas") {
                    DetailRow("Up to date", "\(updated)")
                }
            }
            if let strategy = workload.raw.string(at: "spec.strategy.type")
                ?? workload.raw.string(at: "spec.updateStrategy.type") {
                DetailRow("Strategy", strategy)
            }
            if let service = workload.raw.string(at: "spec.serviceName") {
                DetailRow("Service Name", service)
            }
            DetailRow(label: "Images") {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(workload.raw.array(at: "spec.template.spec.containers").enumerated()),
                            id: \.offset) { _, container in
                        Text(container.string(at: "image") ?? "—")
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if let selector = workload.raw.object(at: "spec.selector.matchLabels"), !selector.isEmpty {
                DetailRow(label: "Selector") {
                    FlowLayout(spacing: 4) {
                        ForEach(selector.pairs, id: \.key) { entry in
                            Chip(text: "\(entry.key)=\(entry.value.displayString)", color: .accentColor)
                        }
                    }
                }
            }
        }

        RelatedPodsSection(connection: connection, owner: workload)
    }
}

/// Lists the pods a controller currently owns, resolved by label selector.
struct RelatedPodsSection: View {
    let connection: ClusterConnection
    let owner: KubeObject
    @State private var pods: [KubeObject] = []
    @State private var loaded = false

    var body: some View {
        DetailSection(title: "Pods", systemImage: "cube") {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if pods.isEmpty {
                Text("No pods match this selector").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(pods) { pod in
                    HStack(spacing: 6) {
                        HealthDot(health: pod.health)
                        Text(pod.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(pod.raw.string(at: "status.phase") ?? "—")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        AgeText(date: pod.creationTimestamp)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .task(id: owner.id) { await load() }
    }

    private func load() async {
        loaded = false
        defer { loaded = true }
        guard let client = connection.client, let namespace = owner.namespace,
              let selector = owner.raw.object(at: "spec.selector.matchLabels"), !selector.isEmpty
        else {
            pods = []
            return
        }
        let expression = selector.pairs.map { "\($0.key)=\($0.value.displayString)" }.joined(separator: ",")
        guard let result = try? await client.get(
            path: "/api/v1/namespaces/\(namespace)/pods",
            query: [URLQueryItem(name: "labelSelector", value: expression)]
        ) else {
            pods = []
            return
        }
        // Through `items(of:)` rather than raw: list entries carry no `kind`,
        // so the health dots beside these pods would all read "unknown".
        pods = KubeObject.items(of: result)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Jobs

struct JobSections: View {
    let connection: ClusterConnection
    let job: KubeObject
    let runner: ActionRunner

    /// Bumped after a manual trigger so the runs list picks the new Job up
    /// without waiting for its next poll.
    @State private var runsToken = 0

    var body: some View {
        DetailSection(title: job.kind, systemImage: "hammer") {
            if job.kind == "CronJob" {
                DetailRow("Schedule", job.raw.string(at: "spec.schedule") ?? "—")
                DetailRow("Suspended", (job.raw.bool(at: "spec.suspend") ?? false) ? "Yes" : "No")
                DetailRow("Concurrency", job.raw.string(at: "spec.concurrencyPolicy") ?? "Allow")
                DetailRow("Last Schedule", Age.absolute(KubeDate.parse(job.raw.string(at: "status.lastScheduleTime"))))
                DetailRow("Last Successful",
                          Age.absolute(KubeDate.parse(job.raw.string(at: "status.lastSuccessfulTime"))))
                DetailRow("Active", "\(job.raw.array(at: "status.active").count)")
                DetailRow(label: "Run") {
                    HStack(spacing: 8) {
                        Button("Run Now", systemImage: "play.fill") { trigger() }
                            .controlSize(.small)
                            .disabled(connection.client == nil || runner.isBusy)
                        Text("Creates a Job from the template, as `kubectl create job --from` does.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                DetailRow("Completions", "\(job.raw.int(at: "spec.completions") ?? 1)")
                DetailRow("Parallelism", "\(job.raw.int(at: "spec.parallelism") ?? 1)")
                DetailRow("Active", "\(job.raw.int(at: "status.active") ?? 0)")
                DetailRow("Succeeded", "\(job.raw.int(at: "status.succeeded") ?? 0)")
                DetailRow("Failed", "\(job.raw.int(at: "status.failed") ?? 0)")
                DetailRow("Backoff Limit", "\(job.raw.int(at: "spec.backoffLimit") ?? 6)")
                if let start = KubeDate.parse(job.raw.string(at: "status.startTime")) {
                    DetailRow("Started", Age.absolute(start))
                }
                if let completion = KubeDate.parse(job.raw.string(at: "status.completionTime")),
                   let start = KubeDate.parse(job.raw.string(at: "status.startTime")) {
                    DetailRow("Duration", Age.short(seconds: completion.timeIntervalSince(start)))
                }
            }
        }

        if job.kind == "CronJob" {
            CronJobRunsSection(connection: connection, cronJob: job, reloadToken: runsToken)
        }
    }

    private func trigger() {
        guard let client = connection.client else { return }
        runner.run("Triggered \(job.name)") {
            let name = try await ResourceActions.triggerCronJob(client: client, object: job)
            runsToken += 1
            return "Created job \(name)"
        }
    }
}

/// The Jobs a CronJob has produced, so a manual run is visible the moment it
/// lands rather than being an action with no feedback.
struct CronJobRunsSection: View {
    let connection: ClusterConnection
    let cronJob: KubeObject
    var reloadToken = 0

    @State private var jobs: [KubeObject] = []
    @State private var loaded = false
    @State private var errorMessage: String?

    private static let shown = 8

    var body: some View {
        DetailSection(title: "Runs", systemImage: "clock.arrow.circlepath") {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if jobs.isEmpty {
                Text("This CronJob has not created any jobs yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(jobs.prefix(Self.shown)) { run in
                    HStack(spacing: 6) {
                        HealthDot(health: run.health)
                        Text(run.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if run.annotations.contains(where: {
                            $0.key == "cronjob.kubernetes.io/instantiate"
                        }) {
                            Chip(text: "manual", color: .accentColor)
                        }
                        Spacer()
                        Text(Self.summary(of: run))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        AgeText(date: run.creationTimestamp)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 1)
                }
                if jobs.count > Self.shown {
                    Text("and \(jobs.count - Self.shown) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Polls rather than watches: a CronJob's Jobs change on the schedule's
        // timescale, and a watch per inspector tab is not worth the connection.
        .task(id: "\(cronJob.id)|\(reloadToken)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private static func summary(of run: KubeObject) -> String {
        let succeeded = run.raw.int(at: "status.succeeded") ?? 0
        let failed = run.raw.int(at: "status.failed") ?? 0
        let active = run.raw.int(at: "status.active") ?? 0
        if active > 0 { return "\(active) active" }
        if failed > 0 { return "\(failed) failed" }
        if succeeded > 0 { return "\(succeeded) succeeded" }
        return "pending"
    }

    private func load() async {
        defer { loaded = true }
        guard let client = connection.client, let namespace = cronJob.namespace else { return }
        do {
            jobs = try await WorkloadPods.jobs(client: client, cronJob: cronJob, namespace: namespace)
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = ClusterConnection.describe(error) }
        }
    }
}

// MARK: - ConfigMaps and Secrets

struct DataSections: View {
    let object: KubeObject
    @State private var revealed: Set<String> = []

    private var isSecret: Bool { object.kind == "Secret" }

    var body: some View {
        DetailSection(title: "Data", systemImage: isSecret ? "key" : "doc.plaintext") {
            if isSecret {
                DetailRow("Type", object.raw.string(at: "type") ?? "Opaque")
            }
            let entries = (object.raw.object(at: "data")?.pairs ?? [])
                + (object.raw.object(at: "binaryData")?.pairs ?? [])
            if entries.isEmpty {
                Text("No data").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.key) { entry in
                DataEntryView(
                    key: entry.key,
                    raw: entry.value.displayString,
                    isSecret: isSecret,
                    revealed: revealed.contains(entry.key),
                    toggle: {
                        if revealed.contains(entry.key) {
                            revealed.remove(entry.key)
                        } else {
                            revealed.insert(entry.key)
                        }
                    }
                )
            }
        }
    }
}

struct DataEntryView: View {
    let key: String
    let raw: String
    let isSecret: Bool
    let revealed: Bool
    let toggle: () -> Void

    /// Secret values arrive base64-encoded; ConfigMap values do not.
    private var decoded: String {
        guard isSecret else { return raw }
        guard let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters) else { return raw }
        return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of binary data>"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(key).font(.system(size: 11, weight: .medium))
                Spacer()
                if isSecret {
                    Button(revealed ? "Hide" : "Reveal", action: toggle)
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
                Button {
                    ResourceActions.copyToPasteboard(decoded)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .help("Copy value")
            }
            if isSecret, !revealed {
                Text(String(repeating: "•", count: min(48, max(8, decoded.count))))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(decoded)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(20)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
        .padding(.vertical, 2)
    }
}

// MARK: - Volumes

struct VolumeSections: View {
    let object: KubeObject

    var body: some View {
        DetailSection(title: object.kind, systemImage: "externaldrive") {
            DetailRow("Phase", object.raw.string(at: "status.phase") ?? "—")
            DetailRow("Storage Class", object.raw.string(at: "spec.storageClassName") ?? "—")
            DetailRow("Access Modes",
                      object.raw.array(at: "spec.accessModes").map(\.displayString).joined(separator: ", "))
            if object.kind == "PersistentVolumeClaim" {
                DetailRow("Requested",
                          object.raw.string(at: "spec.resources.requests.storage") ?? "—")
                DetailRow("Capacity", object.raw.string(at: "status.capacity.storage") ?? "—")
                DetailRow("Volume", object.raw.string(at: "spec.volumeName") ?? "—")
            } else {
                DetailRow("Capacity", object.raw.string(at: "spec.capacity.storage") ?? "—")
                DetailRow("Reclaim Policy", object.raw.string(at: "spec.persistentVolumeReclaimPolicy") ?? "—")
                if let claim = object.raw.value(at: "spec.claimRef") {
                    DetailRow("Claim",
                              "\(claim.string(at: "namespace") ?? "")/\(claim.string(at: "name") ?? "")")
                }
            }
        }
    }
}

// MARK: - Ingress

struct IngressSections: View {
    let ingress: KubeObject

    var body: some View {
        DetailSection(title: "Ingress", systemImage: "arrow.right.to.line") {
            DetailRow("Class", ingress.raw.string(at: "spec.ingressClassName") ?? "—")
            let addresses = ingress.raw.array(at: "status.loadBalancer.ingress").compactMap {
                $0.string(at: "ip") ?? $0.string(at: "hostname")
            }
            DetailRow("Address", addresses.joined(separator: ", "))
            let tls = ingress.raw.array(at: "spec.tls")
            if !tls.isEmpty {
                DetailRow(label: "TLS") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(tls.enumerated()), id: \.offset) { _, entry in
                            Text("\(entry.array(at: "hosts").map(\.displayString).joined(separator: ", "))"
                                 + " → \(entry.string(at: "secretName") ?? "?")")
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                    }
                }
            }
        }

        DetailSection(title: "Rules", systemImage: "list.bullet.indent") {
            ForEach(Array(ingress.raw.array(at: "spec.rules").enumerated()), id: \.offset) { _, rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.string(at: "host") ?? "*")
                        .font(.system(size: 11, weight: .medium))
                    ForEach(Array(rule.array(at: "http.paths").enumerated()), id: \.offset) { _, path in
                        let service = path.value(at: "backend.service")
                        Text("\(path.string(at: "path") ?? "/")"
                             + "  [\(path.string(at: "pathType") ?? "Prefix")]"
                             + " → \(service?.string(at: "name") ?? "?")"
                             + ":\(service?["port"]?["number"]?.displayString ?? service?["port"]?["name"]?.displayString ?? "?")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Namespace

struct NamespaceSections: View {
    let connection: ClusterConnection
    let namespace: KubeObject
    @State private var counts: [(String, Int)] = []

    var body: some View {
        DetailSection(title: "Namespace", systemImage: "square.stack.3d.up") {
            DetailRow("Phase", namespace.raw.string(at: "status.phase") ?? "—")
            ForEach(counts, id: \.0) { entry in
                DetailRow(entry.0, "\(entry.1)")
            }
        }
        .task(id: namespace.id) { await loadCounts() }
    }

    private func loadCounts() async {
        guard let client = connection.client else { return }
        let kinds: [(String, String)] = [
            ("Pods", "/api/v1/namespaces/\(namespace.name)/pods"),
            ("Deployments", "/apis/apps/v1/namespaces/\(namespace.name)/deployments"),
            ("Services", "/api/v1/namespaces/\(namespace.name)/services"),
            ("ConfigMaps", "/api/v1/namespaces/\(namespace.name)/configmaps"),
            ("Secrets", "/api/v1/namespaces/\(namespace.name)/secrets"),
        ]
        var result: [(String, Int)] = []
        for (title, path) in kinds {
            if let list = try? await client.get(
                path: path, query: [URLQueryItem(name: "limit", value: "500")]
            ) {
                result.append((title, list.array(at: "items").count))
            }
        }
        counts = result
    }
}

// MARK: - RBAC

struct RBACSections: View {
    let object: KubeObject

    var body: some View {
        switch object.kind {
        case "Role", "ClusterRole":
            DetailSection(title: "Rules", systemImage: "list.bullet.rectangle") {
                ForEach(Array(object.raw.array(at: "rules").enumerated()), id: \.offset) { _, rule in
                    VStack(alignment: .leading, spacing: 2) {
                        DetailRow("API Groups",
                                  rule.array(at: "apiGroups").map { $0.displayString.isEmpty ? "core" : $0.displayString }
                                      .joined(separator: ", "))
                        DetailRow("Resources",
                                  rule.array(at: "resources").map(\.displayString).joined(separator: ", "))
                        DetailRow("Verbs", rule.array(at: "verbs").map(\.displayString).joined(separator: ", "))
                        if !rule.array(at: "resourceNames").isEmpty {
                            DetailRow("Names",
                                      rule.array(at: "resourceNames").map(\.displayString).joined(separator: ", "))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.vertical, 2)
                }
            }
        case "RoleBinding", "ClusterRoleBinding":
            DetailSection(title: "Binding", systemImage: "link") {
                DetailRow("Role",
                          "\(object.raw.string(at: "roleRef.kind") ?? "?")/"
                          + "\(object.raw.string(at: "roleRef.name") ?? "?")")
                DetailRow(label: "Subjects") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(object.raw.array(at: "subjects").enumerated()), id: \.offset) { _, subject in
                            Text("\(subject.string(at: "kind") ?? "?"): "
                                 + (subject.string(at: "namespace").map { "\($0)/" } ?? "")
                                 + (subject.string(at: "name") ?? "?"))
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                    }
                }
            }
        case "ServiceAccount":
            DetailSection(title: "Service Account", systemImage: "person.badge.key") {
                DetailRow("Automount",
                          (object.raw.bool(at: "automountServiceAccountToken") ?? true) ? "Yes" : "No")
                DetailRow("Secrets",
                          object.raw.array(at: "secrets").compactMap { $0.string(at: "name") }
                              .joined(separator: ", "))
                DetailRow("Image Pull Secrets",
                          object.raw.array(at: "imagePullSecrets").compactMap { $0.string(at: "name") }
                              .joined(separator: ", "))
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - HPA

struct AutoscalerSections: View {
    let object: KubeObject

    var body: some View {
        DetailSection(title: "Autoscaler", systemImage: "arrow.up.left.and.arrow.down.right") {
            DetailRow("Target",
                      "\(object.raw.string(at: "spec.scaleTargetRef.kind") ?? "?")/"
                      + "\(object.raw.string(at: "spec.scaleTargetRef.name") ?? "?")")
            DetailRow("Replicas",
                      "\(object.raw.int(at: "status.currentReplicas") ?? 0) current · "
                      + "\(object.raw.int(at: "status.desiredReplicas") ?? 0) desired")
            DetailRow("Bounds",
                      "\(object.raw.int(at: "spec.minReplicas") ?? 1) – "
                      + "\(object.raw.int(at: "spec.maxReplicas") ?? 0)")
            let metrics = object.raw.array(at: "spec.metrics")
            if !metrics.isEmpty {
                DetailRow(label: "Metrics") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                            Text(AutoscalerSections.summary(metric))
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    static func summary(_ metric: JSONValue) -> String {
        let type = metric.string(at: "type") ?? "?"
        let key = type.prefix(1).lowercased() + type.dropFirst()
        guard let body = metric[String(key)] else { return type }
        let name = body.string(at: "name") ?? body.string(at: "metric.name") ?? type
        if let average = body.int(at: "target.averageUtilization") { return "\(name): \(average)% average" }
        if let value = body.string(at: "target.averageValue") { return "\(name): \(value) average" }
        if let value = body.string(at: "target.value") { return "\(name): \(value)" }
        return name
    }
}
