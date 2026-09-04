import SwiftUI

/// The environment a pod's containers actually receive: `envFrom` sources and
/// `env` entries merged the way the kubelet merges them, with ConfigMap and
/// Secret references resolved against the cluster so a row shows the value
/// instead of a pointer to it.
///
/// Resolution is best-effort on purpose. Reading Secrets is a privilege plenty
/// of users do not have, and a source that is missing or forbidden is reported
/// on its own row rather than failing the section — a partially resolved
/// environment is still far more useful than the raw spec.
struct PodEnvironmentSection: View {
    let connection: ClusterConnection
    let pod: KubeObject

    @State private var sources: [EnvSourceRef: EnvSourceState] = [:]
    @State private var loaded = false
    @State private var selection: String?
    @State private var search = ""
    @State private var revealed: Set<String> = []

    private var containers: [EnvContainer] { EnvContainer.all(in: pod) }

    private var container: EnvContainer? {
        containers.first { $0.name == selection } ?? containers.first
    }

    private var variables: [EnvVariable] {
        guard let container else { return [] }
        return PodEnvironment.variables(of: container.spec, pod: pod, sources: sources, loaded: loaded)
    }

    /// The filter matches names and values alike, so hunting for the pod that
    /// carries a particular endpoint works as well as hunting for a name.
    private var shown: [EnvVariable] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return variables }
        return variables.filter {
            $0.name.lowercased().contains(needle) || ($0.value?.lowercased().contains(needle) ?? false)
        }
    }

    private var secretKeys: [String] { variables.filter(\.isSecret).map(revealKey) }

    private var allRevealed: Bool {
        !secretKeys.isEmpty && secretKeys.allSatisfy { revealed.contains($0) }
    }

    var body: some View {
        DetailSection(title: "Environment", systemImage: "curlybraces") {
            if containers.isEmpty {
                Text("This pod declares no containers.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                controls
                if variables.isEmpty {
                    Text("This container declares no environment variables.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if shown.isEmpty {
                    Text("No variable matches “\(search)”.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { variable in
                        EnvVariableRow(
                            variable: variable,
                            revealed: revealed.contains(revealKey(variable)),
                            toggle: { toggle(variable) }
                        )
                    }
                    Text("The kubelet also injects service discovery variables "
                         + "(KUBERNETES_SERVICE_HOST and friends) that never appear in the spec.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
            }
        }
        .task(id: pod.id) { await load() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if containers.count > 1 {
                Picker("", selection: Binding(
                    get: { container?.name ?? "" },
                    set: { selection = $0 }
                )) {
                    ForEach(containers) { entry in
                        Text(entry.label).tag(entry.name)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("Filter", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .frame(maxWidth: 130)
            }
            if !loaded {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 4)
            if !secretKeys.isEmpty {
                Button(allRevealed ? "Hide secrets" : "Reveal secrets") {
                    if allRevealed {
                        secretKeys.forEach { revealed.remove($0) }
                    } else {
                        revealed.formUnion(secretKeys)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.tint)
            }
            Button {
                ResourceActions.copyToPasteboard(
                    shown.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "\n")
                )
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy the listed variables as NAME=value")
        }
        .padding(.bottom, 2)
    }

    /// Reveal state is per container, so two containers holding the same
    /// variable name do not unmask each other.
    private func revealKey(_ variable: EnvVariable) -> String {
        "\(container?.name ?? "")/\(variable.id)"
    }

    private func toggle(_ variable: EnvVariable) {
        let key = revealKey(variable)
        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
    }

    /// Fetches every ConfigMap and Secret the pod's containers reference, once
    /// each — a pod that mounts the same ConfigMap into five containers costs
    /// one request, and the fan-out is concurrent because a pod referencing a
    /// dozen sources would otherwise serialise a dozen round trips.
    private func load() async {
        let refs = PodEnvironment.sourceRefs(in: pod)
        guard let client = connection.client, let namespace = pod.namespace, !refs.isEmpty else {
            sources = [:]
            loaded = true
            return
        }
        loaded = false
        sources = [:]
        sources = await withTaskGroup(of: (EnvSourceRef, EnvSourceState).self) { group in
            for ref in refs {
                group.addTask {
                    do {
                        let object = try await client.get(path: ref.path(namespace: namespace))
                        return (ref, .data(PodEnvironment.entries(of: object, isSecret: ref.isSecret)))
                    } catch {
                        return (ref, .failed(PodEnvironment.reason(for: error, ref: ref)))
                    }
                }
            }
            var resolved: [EnvSourceRef: EnvSourceState] = [:]
            for await (ref, state) in group { resolved[ref] = state }
            return resolved
        }
        loaded = true
    }
}

// MARK: - Row

private struct EnvVariableRow: View {
    let variable: EnvVariable
    let revealed: Bool
    let toggle: () -> Void

    @State private var expanded = false

    /// Certificates, JDBC URLs and JSON blobs all show up in environments, so
    /// long values fold instead of pushing the rest of the list off screen.
    private var isLong: Bool {
        guard let value = variable.value else { return false }
        return value.contains("\n") || value.count > 160
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(variable.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                if let origin = variable.origin {
                    Chip(text: origin, color: variable.isSecret ? .orange : .secondary)
                }
                Spacer(minLength: 4)
                if isLong {
                    Button(expanded ? "less" : "more") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
                if variable.isSecret, variable.value != nil {
                    Button {
                        toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(revealed ? "Hide value" : "Reveal value")
                }
                if let value = variable.value {
                    Button {
                        ResourceActions.copyToPasteboard(value)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy value")
                }
            }
            value
            if variable.value != nil, let note = variable.note {
                Text(note).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2.5)
    }

    @ViewBuilder
    private var value: some View {
        if let value = variable.value {
            if variable.isSecret, !revealed {
                Text(String(repeating: "•", count: min(40, max(6, value.count))))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if value.isEmpty {
                Text("(empty)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                Text(value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
            }
        } else {
            Text(variable.note ?? "unresolved")
                .font(.system(size: 10))
                .foregroundStyle(variable.isPending ? Color.secondary : Color.orange)
        }
    }
}

// MARK: - Model

/// One container to list an environment for. Init and ephemeral containers are
/// included: the environment of a crash-looping init container or of a debug
/// container is exactly what you want to look at.
struct EnvContainer: Identifiable {
    let name: String
    /// `nil` for a regular container, otherwise how it is attached.
    let role: String?
    let spec: JSONValue

    var id: String { name }
    var label: String { role.map { "\(name) (\($0))" } ?? name }

    static func all(in pod: KubeObject) -> [EnvContainer] {
        func list(_ path: String, role: String?) -> [EnvContainer] {
            pod.raw.array(at: path).map {
                EnvContainer(name: $0.string(at: "name") ?? "—", role: role, spec: $0)
            }
        }
        return list("spec.initContainers", role: "init")
            + list("spec.containers", role: nil)
            + list("spec.ephemeralContainers", role: "debug")
    }
}

/// A ConfigMap or Secret an environment refers to.
struct EnvSourceRef: Hashable, Sendable {
    let isSecret: Bool
    let name: String

    func path(namespace: String) -> String {
        "/api/v1/namespaces/\(namespace)/\(isSecret ? "secrets" : "configmaps")/\(name)"
    }

    var kindName: String { isSecret ? "Secret" : "ConfigMap" }
}

enum EnvSourceState: Sendable {
    /// Keys mapped to their decoded values, in the order the server returned.
    case data(JSONObject)
    case failed(String)
}

struct EnvVariable: Identifiable {
    /// The variable's name, except for a placeholder standing in for a whole
    /// unresolved `envFrom` source, whose keys are unknown.
    let id: String
    let name: String
    /// `nil` when the value could not be resolved; `note` then says why.
    var value: String?
    /// Where the value came from — `nil` for a literal, which needs no label.
    var origin: String?
    var isSecret = false
    var note: String?
    /// A note that reads as "still working", not "went wrong".
    var isPending = false
}

enum PodEnvironment {
    /// Every distinct ConfigMap and Secret the pod's containers name.
    static func sourceRefs(in pod: KubeObject) -> [EnvSourceRef] {
        var refs: [EnvSourceRef] = []
        func add(_ ref: EnvSourceRef) { if !refs.contains(ref) { refs.append(ref) } }

        for container in EnvContainer.all(in: pod) {
            for source in container.spec.array(at: "envFrom") {
                if let name = source.string(at: "configMapRef.name") {
                    add(EnvSourceRef(isSecret: false, name: name))
                }
                if let name = source.string(at: "secretRef.name") {
                    add(EnvSourceRef(isSecret: true, name: name))
                }
            }
            for variable in container.spec.array(at: "env") {
                if let name = variable.string(at: "valueFrom.configMapKeyRef.name") {
                    add(EnvSourceRef(isSecret: false, name: name))
                }
                if let name = variable.string(at: "valueFrom.secretKeyRef.name") {
                    add(EnvSourceRef(isSecret: true, name: name))
                }
            }
        }
        return refs
    }

    /// Merges a container's environment the way the kubelet does: `envFrom`
    /// sources in order first, then `env`, with a later definition winning the
    /// name it repeats but keeping the position of the first.
    static func variables(
        of container: JSONValue,
        pod: KubeObject,
        sources: [EnvSourceRef: EnvSourceState],
        loaded: Bool
    ) -> [EnvVariable] {
        var order: [String] = []
        var byID: [String: EnvVariable] = [:]

        func put(_ variable: EnvVariable) {
            if byID[variable.id] == nil { order.append(variable.id) }
            byID[variable.id] = variable
        }

        func state(_ ref: EnvSourceRef) -> EnvSourceState {
            sources[ref] ?? .failed(loaded ? "\(ref.kindName) \(ref.name) was not resolved" : "resolving…")
        }

        for source in container.array(at: "envFrom") {
            let prefix = source.string(at: "prefix") ?? ""
            for isSecret in [false, true] {
                let field = isSecret ? "secretRef" : "configMapRef"
                guard let ref = source[field], let name = ref.string(at: "name") else { continue }
                let origin = EnvSourceRef(isSecret: isSecret, name: name)
                let optional = ref.bool(at: "optional") ?? false
                switch state(origin) {
                case .data(let data):
                    for entry in data.pairs {
                        put(EnvVariable(
                            id: prefix + entry.key,
                            name: prefix + entry.key,
                            value: entry.value.stringValue ?? entry.value.displayString,
                            origin: "\(origin.kindName) \(name)",
                            isSecret: isSecret
                        ))
                    }
                case .failed(let reason):
                    // The keys are unknowable without the object, so the whole
                    // source gets one placeholder row rather than vanishing.
                    put(EnvVariable(
                        id: "\(field)/\(name)/\(prefix)",
                        name: prefix.isEmpty ? "*" : "\(prefix)*",
                        origin: "\(origin.kindName) \(name)",
                        isSecret: isSecret,
                        note: optional ? "\(reason) — optional, so the container starts without these" : reason,
                        isPending: !loaded
                    ))
                }
            }
        }

        for entry in container.array(at: "env") {
            guard let name = entry.string(at: "name") else { continue }
            if let literal = entry.string(at: "value") {
                put(EnvVariable(id: name, name: name, value: expand(literal, using: byID)))
                continue
            }
            guard let from = entry["valueFrom"] else {
                // `env` with neither `value` nor `valueFrom` means empty.
                put(EnvVariable(id: name, name: name, value: ""))
                continue
            }
            if let ref = from["configMapKeyRef"] {
                put(keyRef(ref, name: name, isSecret: false, state: state, loaded: loaded))
            } else if let ref = from["secretKeyRef"] {
                put(keyRef(ref, name: name, isSecret: true, state: state, loaded: loaded))
            } else if let path = from.string(at: "fieldRef.fieldPath") {
                let value = fieldValue(path, pod: pod)
                put(EnvVariable(
                    id: name, name: name, value: value, origin: "field \(path)",
                    note: value == nil ? "the kubelet fills this in when the container starts" : nil
                ))
            } else if let ref = from["resourceFieldRef"] {
                put(resourceRef(ref, name: name, container: container, pod: pod))
            } else {
                put(EnvVariable(id: name, name: name, origin: "valueFrom",
                                note: "this source is not one the viewer can resolve"))
            }
        }

        return order.compactMap { byID[$0] }
    }

    private static func keyRef(
        _ ref: JSONValue,
        name: String,
        isSecret: Bool,
        state: (EnvSourceRef) -> EnvSourceState,
        loaded: Bool
    ) -> EnvVariable {
        let sourceName = ref.string(at: "name") ?? "—"
        let key = ref.string(at: "key") ?? "—"
        let optional = ref.bool(at: "optional") ?? false
        let source = EnvSourceRef(isSecret: isSecret, name: sourceName)
        var variable = EnvVariable(
            id: name, name: name,
            origin: "\(source.kindName) \(sourceName)/\(key)",
            isSecret: isSecret
        )
        switch state(source) {
        case .data(let data):
            if let value = data[key] {
                variable.value = value.stringValue ?? value.displayString
            } else {
                variable.note = optional
                    ? "key \(key) is missing — optional, so the variable is unset"
                    : "key \(key) is not in this \(source.kindName.lowercased())"
            }
        case .failed(let reason):
            variable.note = optional ? "\(reason) — optional, so the variable is unset" : reason
            variable.isPending = !loaded
        }
        return variable
    }

    /// `resourceFieldRef` is reported as the container declares it. The kubelet
    /// substitutes the node's allocatable capacity when a request or limit is
    /// unset, and applies the divisor, neither of which is knowable from here —
    /// so both are stated rather than guessed at.
    private static func resourceRef(
        _ ref: JSONValue,
        name: String,
        container: JSONValue,
        pod: KubeObject
    ) -> EnvVariable {
        let resource = ref.string(at: "resource") ?? "—"
        let target = ref.string(at: "containerName") ?? container.string(at: "name") ?? ""
        let spec = EnvContainer.all(in: pod).first { $0.name == target }?.spec ?? container
        let declared = spec.value(at: "resources.\(resource)")?.displayString
        let divisor = ref["divisor"]?.displayString
        var note: String?
        if declared == nil {
            note = "not set on \(target) — the kubelet substitutes the node's allocatable capacity"
        } else if let divisor, !divisor.isEmpty, divisor != "1" {
            note = "divided by \(divisor) when the container starts"
        }
        return EnvVariable(
            id: name, name: name, value: declared,
            origin: "resource \(resource) of \(target)", note: note
        )
    }

    /// The kubelet expands `$(OTHER)` against variables defined earlier in the
    /// same container and treats `$$` as an escaped dollar. Doing the same here
    /// keeps the viewer honest about what the process really sees; a reference
    /// that resolves to nothing is left standing, exactly as the kubelet leaves
    /// it.
    static func expand(_ value: String, using resolved: [String: EnvVariable]) -> String {
        guard value.contains("$") else { return value }
        var out = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if character == "$", next < value.endIndex {
                if value[next] == "$" {
                    out.append("$")
                    index = value.index(after: next)
                    continue
                }
                if value[next] == "(", let close = value[next...].firstIndex(of: ")") {
                    let key = String(value[value.index(after: next)..<close])
                    out += resolved[key]?.value ?? "$(\(key))"
                    index = value.index(after: close)
                    continue
                }
            }
            out.append(character)
            index = next
        }
        return out
    }

    /// `metadata.labels['app.kubernetes.io/name']` cannot go through the dotted
    /// path lookup, because the key itself contains dots.
    static func fieldValue(_ path: String, pod: KubeObject) -> String? {
        if let open = path.firstIndex(of: "["), path.hasSuffix("]") {
            let parent = String(path[path.startIndex..<open])
            let quoted = path[path.index(after: open)..<path.index(before: path.endIndex)]
            let key = quoted.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            return pod.raw.object(at: parent)?[key]?.displayString
        }
        guard let value = pod.raw.value(at: path), !value.isNull else { return nil }
        return value.displayString
    }

    /// Secret values arrive base64-encoded; ConfigMap values do not. Only
    /// `data` is read: `binaryData` cannot back an environment variable.
    static func entries(of object: JSONValue, isSecret: Bool) -> JSONObject {
        var out = JSONObject()
        for entry in object.object(at: "data")?.pairs ?? [] {
            let raw = entry.value.displayString
            out[entry.key] = .string(isSecret ? decode(raw) : raw)
        }
        return out
    }

    private static func decode(_ base64: String) -> String {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return base64 }
        return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of binary data>"
    }

    static func reason(for error: Error, ref: EnvSourceRef) -> String {
        if let status = error as? KubeStatusError {
            if status.isNotFound { return "\(ref.kindName) \(ref.name) does not exist" }
            if status.isForbidden { return "not allowed to read \(ref.kindName.lowercased()) \(ref.name)" }
        }
        return ClusterConnection.describe(error)
    }
}
