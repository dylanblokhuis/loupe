import SwiftUI

/// The summary tab. Every object gets metadata, owners and conditions; kinds the
/// app understands get a purpose-built section, and everything else falls back
/// to a browsable tree of its spec and status.
struct ObjectOverview: View {
    let connection: ClusterConnection
    let object: KubeObject
    /// Shared with the inspector so a section's action reports through the same
    /// banner as the actions menu.
    let runner: ActionRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metadataSection
            if !object.ownerReferences.isEmpty { ownersSection }
            kindSection
            if !object.conditions.isEmpty { conditionsSection }
            fallbackSection
        }
    }

    // MARK: Generic sections

    private var metadataSection: some View {
        DetailSection(title: "Metadata", systemImage: "tag") {
            DetailRow("Name", object.name)
            if let namespace = object.namespace { DetailRow("Namespace", namespace) }
            DetailRow("Created", Age.absolute(object.creationTimestamp))
            DetailRow(label: "Age") { AgeText(date: object.creationTimestamp) }
            if let deletion = object.deletionTimestamp {
                DetailRow("Deleting since", Age.absolute(deletion))
            }
            DetailRow("UID", object.uid)
            if !object.labels.isEmpty {
                DetailRow(label: "Labels") {
                    FlowLayout(spacing: 4) {
                        ForEach(object.labels, id: \.key) { label in
                            Chip(text: "\(label.key)=\(label.value)", color: .accentColor)
                        }
                    }
                }
            }
            if !object.annotations.isEmpty {
                DetailRow(label: "Annotations") {
                    AnnotationList(annotations: object.annotations)
                }
            }
        }
    }

    private var ownersSection: some View {
        DetailSection(title: "Controlled By", systemImage: "arrow.turn.up.left") {
            ForEach(object.ownerReferences, id: \.uid) { owner in
                DetailRow(label: owner.kind) {
                    Text(owner.name).foregroundStyle(.tint)
                }
            }
        }
    }

    private var conditionsSection: some View {
        DetailSection(title: "Conditions", systemImage: "checklist") {
            ForEach(object.conditions) { condition in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: condition.isTrue
                            ? "checkmark.circle.fill"
                            : (condition.status == "Unknown" ? "questionmark.circle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(condition.isTrue ? Color.green
                                : (condition.status == "Unknown" ? Color.secondary : Color.orange))
                            .font(.system(size: 10))
                        Text(condition.type).font(.system(size: 11.5, weight: .medium))
                        if let reason = condition.reason, !reason.isEmpty {
                            Chip(text: reason, color: .secondary)
                        }
                        Spacer()
                        if let time = condition.lastTransitionTime {
                            Text(Age.short(since: time))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let message = condition.message, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 18)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var kindSection: some View {
        switch object.kind {
        case "Pod": PodSections(connection: connection, pod: object)
        case "Node": NodeSections(connection: connection, node: object)
        case "Service": ServiceSections(connection: connection, service: object)
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController":
            WorkloadSections(connection: connection, workload: object)
        case "Job", "CronJob": JobSections(connection: connection, job: object, runner: runner)
        case "ConfigMap", "Secret": DataSections(object: object)
        case "PersistentVolumeClaim", "PersistentVolume": VolumeSections(object: object)
        case "Ingress": IngressSections(ingress: object)
        case "Namespace": NamespaceSections(connection: connection, namespace: object)
        case "ServiceAccount", "Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding":
            RBACSections(object: object)
        case "HorizontalPodAutoscaler": AutoscalerSections(object: object)
        default: EmptyView()
        }
    }

    /// Top-level fields beyond the standard four — `data`, `rules`, `subjects`
    /// and whatever a custom resource invents.
    private var extraKeys: [String] {
        (object.raw.objectValue?.keys ?? []).filter {
            !["apiVersion", "kind", "metadata", "spec", "status"].contains($0)
        }
    }

    /// Raw spec/status for kinds without a bespoke section — this is what makes
    /// custom resources genuinely browsable.
    @ViewBuilder
    private var fallbackSection: some View {
        let handled: Set<String> = [
            "Pod", "Node", "Service", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet",
            "ReplicationController", "Job", "CronJob", "ConfigMap", "Secret",
            "PersistentVolumeClaim", "PersistentVolume", "Ingress", "Namespace",
        ]
        if !handled.contains(object.kind) {
            if let spec = object.raw["spec"], !spec.isNull {
                DetailSection(title: "Spec", systemImage: "doc.text.magnifyingglass") {
                    JSONTreeView(value: spec)
                }
            }
            if let status = object.raw["status"], !status.isNull {
                DetailSection(title: "Status", systemImage: "waveform.path.ecg") {
                    JSONTreeView(value: status.removing("conditions"))
                }
            }
            ForEach(extraKeys, id: \.self) { key in
                if let value = object.raw[key] {
                    DetailSection(title: key.prefix(1).uppercased() + key.dropFirst()) {
                        JSONTreeView(value: value)
                    }
                }
            }
        }
    }
}

/// Annotations are often long (last-applied-configuration, nginx config
/// snippets), so the list collapses and each large value expands into a
/// code block instead of wrapping forever.
struct AnnotationList: View {
    let annotations: [(key: String, value: String)]
    @State private var showAll = false

    private var shown: [(key: String, value: String)] {
        showAll ? annotations : Array(annotations.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown, id: \.key) { annotation in
                AnnotationRow(key: annotation.key, value: annotation.value)
            }
            if annotations.count > 4 {
                Button(showAll ? "Show less" : "Show all \(annotations.count)") {
                    showAll.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.tint)
            }
        }
    }
}

private struct AnnotationRow: View {
    let key: String
    let value: String
    @State private var expanded = false

    /// Multi-line or long values trade inline text for the expandable block.
    private var isLarge: Bool { value.contains("\n") || value.count > 140 }

    /// Pathological values (last-applied-configuration can run to hundreds of
    /// KB) are cut for display; Copy always yields the full value.
    private static let displayCap = 20_000

    var body: some View {
        if isLarge {
            expandable
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var expandable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(key)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(sizeLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button {
                    ResourceActions.copyToPasteboard(value)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy value")
            }
            if expanded {
                codeBlock
            } else {
                Text(preview)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 13)
            }
        }
    }

    private var sizeLabel: String {
        let lines = value.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        return lines > 1 ? "\(lines) lines" : "\(value.count) chars"
    }

    private var preview: String {
        String(value.prefix(300).prefix(while: { $0 != "\n" }))
    }

    private var isCapped: Bool { value.count > Self.displayCap }

    /// Lines keep their layout and scroll horizontally rather than wrapping,
    /// which is what makes nginx snippets and JSON blobs legible in a narrow
    /// inspector.
    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(isCapped ? String(value.prefix(Self.displayCap)) : value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            if isCapped {
                Text("Showing first \(Self.displayCap.formatted()) characters — Copy has the full value")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding([.horizontal, .bottom], 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
        .padding(.top, 3)
        .padding(.leading, 13)
    }
}

/// Collapsible renderer for arbitrary JSON — the generic fallback for kinds the
/// app has no bespoke layout for.
struct JSONTreeView: View {
    let value: JSONValue
    var depth: Int = 0

    var body: some View {
        switch value {
        case .object(let object):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(object.keys, id: \.self) { key in
                    node(key: key, value: object[key] ?? .null)
                }
            }
        case .array(let items):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    node(key: "[\(index)]", value: item)
                }
            }
        default:
            Text(value.displayString)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func node(key: String, value: JSONValue) -> some View {
        switch value {
        case .object(let object) where !object.isEmpty:
            BranchNode(key: key, count: object.count, startExpanded: depth < 1) {
                JSONTreeView(value: value, depth: depth + 1)
            }
        case .array(let items) where !items.isEmpty:
            BranchNode(key: key, count: items.count, startExpanded: depth < 1) {
                JSONTreeView(value: value, depth: depth + 1)
            }
        default:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value.displayString.isEmpty ? "—" : value.displayString)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
        }
    }

    private struct BranchNode<Content: View>: View {
        let key: String
        let count: Int
        let startExpanded: Bool
        @ViewBuilder var content: Content
        @State private var expanded: Bool?

        var body: some View {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded ?? startExpanded },
                set: { expanded = $0 }
            )) {
                content.padding(.leading, 10)
            } label: {
                HStack(spacing: 5) {
                    Text(key).font(.system(size: 10.5, weight: .medium))
                    Text("\(count)").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
