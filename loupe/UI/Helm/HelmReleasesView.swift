import Compression
import SwiftUI

/// Lists Helm v3 releases.
///
/// Helm keeps no server-side API of its own: every release revision lives in a
/// `helm.sh/release.v1` Secret whose `release` key holds gzipped JSON, base64'd
/// twice (once by Helm, once by the Secret encoding). Reading those Secrets is
/// exactly what the CLI does, so no extra cluster component is required.
struct HelmReleasesView: View {
    let connection: ClusterConnection
    @Binding var inspection: InspectionTarget?

    @State private var model: HelmReleasesModel
    @State private var expanded: Set<String> = []

    init(connection: ClusterConnection, inspection: Binding<InspectionTarget?>) {
        self.connection = connection
        self._inspection = inspection
        self._model = State(wrappedValue: HelmReleasesModel(connection: connection))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let warning = model.warningMessage {
                Banner(message: warning, tint: .red) { model.warningMessage = nil }
            }
            content
        }
        .toolbar { toolbarContent }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search releases")
        .navigationTitle("Helm Releases")
        .task(id: connection.selectedNamespaces) { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.releases.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading Helm release secrets…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            EmptyStateView(
                title: "Could not list Helm releases",
                message: error,
                systemImage: "exclamationmark.triangle",
                action: ("Retry", { Task { await model.load() } })
            )
        } else if model.releases.isEmpty {
            EmptyStateView(
                title: "No Helm releases",
                message: "No Helm v3 release secrets were found in \(scopeDescription). "
                    + "Releases installed with Helm 2, or stored in ConfigMaps or another backend, "
                    + "are not shown.",
                systemImage: "sailboat",
                action: ("Refresh", { Task { await model.load() } })
            )
        } else if model.filteredReleases.isEmpty {
            EmptyStateView(
                title: "No matching releases",
                message: "\(model.releases.count) releases are loaded, none match “\(model.searchText)”.",
                systemImage: "magnifyingglass"
            )
        } else {
            table
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HelmColumn.header
            Divider()
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.filteredReleases) { release in
                        HelmReleaseRowView(
                            release: release,
                            isExpanded: expanded.contains(release.id),
                            toggle: {
                                if expanded.contains(release.id) {
                                    expanded.remove(release.id)
                                } else {
                                    expanded.insert(release.id)
                                }
                            },
                            inspect: inspect
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("\(model.filteredReleases.count) of \(model.releases.count)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if model.truncated {
                Chip(text: "truncated", color: .orange, systemImage: "scissors")
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.mini)
            } else if let updated = model.lastUpdated {
                Text("updated \(Age.short(since: updated)) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.isLoading)
        }
    }

    /// Opens the inspector on the Secret a revision was decoded from.
    private func inspect(_ revision: HelmRevision) {
        inspection = InspectionTarget(
            object: revision.secret,
            resource: connection.catalog.resource(kind: "Secret", group: "")
        )
    }

    private var scopeDescription: String {
        guard let namespaces = connection.effectiveNamespaces else { return "any namespace" }
        return namespaces.joined(separator: ", ")
    }
}

// MARK: - Row

private struct HelmReleaseRowView: View {
    let release: HelmRelease
    let isExpanded: Bool
    var toggle: () -> Void
    var inspect: (HelmRevision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isExpanded {
                Divider().padding(.vertical, 6)
                detail
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu { menu }
    }

    private var summary: some View {
        let latest = release.latest
        return Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: HelmColumn.disclosure, alignment: .leading)
                Text(release.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                cell(release.namespace, width: HelmColumn.namespace)
                cell(latest.chartLabel, width: HelmColumn.chart)
                cell(latest.appVersion, width: HelmColumn.appVersion)
                Text("\(latest.revision)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: HelmColumn.revision, alignment: .leading)
                HStack(spacing: 0) {
                    Chip(text: latest.status, color: latest.statusColor)
                    Spacer(minLength: 0)
                }
                .frame(width: HelmColumn.status)
                AgeText(date: latest.updated)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: HelmColumn.updated, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !release.latest.description.isEmpty {
                Text(release.latest.description)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(release.revisions.count) stored revision\(release.revisions.count == 1 ? "" : "s")")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 2)
            ForEach(release.revisions) { revision in
                revisionRow(revision)
            }
        }
        .padding(.leading, HelmColumn.disclosure + 8)
    }

    private func revisionRow(_ revision: HelmRevision) -> some View {
        HStack(spacing: 8) {
            Text("#\(revision.revision)")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .frame(width: 34, alignment: .leading)
            Chip(text: revision.status, color: revision.statusColor)
            Text(revision.chartLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: HelmColumn.chart, alignment: .leading)
            Text(revision.description)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Age.absolute(revision.updated))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button("Secret") { inspect(revision) }
                .buttonStyle(.link)
                .font(.system(size: 10))
                .help(revision.secret.name)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Show Release Secret") { inspect(release.latest) }
        Divider()
        Button("Copy Name") { ResourceActions.copyToPasteboard(release.name) }
        Button("Copy Manifest") { ResourceActions.copyToPasteboard(release.latest.manifest) }
            .disabled(release.latest.manifest.isEmpty)
        Button("Copy Notes") { ResourceActions.copyToPasteboard(release.latest.notes) }
            .disabled(release.latest.notes.isEmpty)
    }
}

private enum HelmColumn {
    static let disclosure: CGFloat = 14
    static let namespace: CGFloat = 118
    static let chart: CGFloat = 158
    static let appVersion: CGFloat = 82
    static let revision: CGFloat = 52
    /// Wide enough for the longest Helm status, `pending-rollback`.
    static let status: CGFloat = 118
    static let updated: CGFloat = 56

    static var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: disclosure, height: 1)
            label("Name").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            label("Namespace").frame(width: namespace, alignment: .leading)
            label("Chart").frame(width: chart, alignment: .leading)
            label("App version").frame(width: appVersion, alignment: .leading)
            label("Rev").frame(width: revision, alignment: .leading)
            label("Status").frame(width: status, alignment: .leading)
            label("Updated").frame(width: updated, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private static func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Model

@MainActor
@Observable
final class HelmReleasesModel {
    private let connection: ClusterConnection

    private(set) var releases: [HelmRelease] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var truncated = false
    private(set) var lastUpdated: Date?
    var warningMessage: String?
    var searchText = ""

    private var generation = 0

    init(connection: ClusterConnection) {
        self.connection = connection
    }

    var filteredReleases: [HelmRelease] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return releases }
        return releases.filter { $0.matches(needle) }
    }

    func load() async {
        guard let client = connection.client else {
            errorMessage = "Not connected to \(connection.name)."
            return
        }
        // A namespace change cancels the running load and starts another, so a
        // superseded run must not report its own cancellation as a failure.
        generation += 1
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }

        let fetches = await HelmLoader.listSecrets(client: client, namespaces: connection.effectiveNamespaces)
        guard token == generation, !Task.isCancelled else { return }
        let lists = fetches.compactMap(\.list)
        let failures = fetches.compactMap { fetch -> String? in
            guard let failure = fetch.failure else { return nil }
            return fetch.namespace.isEmpty ? failure : "\(fetch.namespace): \(failure)"
        }

        guard !lists.isEmpty else {
            errorMessage = failures.first ?? "The API server returned no response."
            warningMessage = nil
            releases = []
            return
        }
        errorMessage = nil
        warningMessage = failures.isEmpty
            ? nil
            : "Some namespaces could not be read — " + failures.joined(separator: "; ")

        // Ungzipping and parsing every revision is real work, so it stays off
        // the main actor even though the fetch itself already has.
        let parsed = await Task.detached(priority: .userInitiated) {
            HelmLoader.releases(from: lists)
        }.value
        guard token == generation else { return }
        releases = parsed
        truncated = lists.contains { !($0.string(at: "metadata.continue") ?? "").isEmpty }
        lastUpdated = Date()
    }
}

// MARK: - Release model

struct HelmRevision: Identifiable, Sendable {
    var releaseName: String
    var namespace: String
    var revision: Int
    var status: String
    var chartName: String
    var chartVersion: String
    var appVersion: String
    var updated: Date?
    var description: String
    var manifest: String
    var notes: String
    var secret: KubeObject

    var id: String { "\(namespace)/\(releaseName)/\(revision)" }

    var chartLabel: String {
        chartVersion.isEmpty ? chartName : "\(chartName)-\(chartVersion)"
    }

    var statusColor: Color {
        let status = status.lowercased()
        if status == "deployed" { return .green }
        if status == "failed" { return .red }
        if status == "uninstalling" || status.hasPrefix("pending") { return .orange }
        return .secondary
    }
}

struct HelmRelease: Identifiable, Sendable {
    var name: String
    var namespace: String
    var latest: HelmRevision
    /// Superseded revisions, newest first.
    var older: [HelmRevision]

    var id: String { "\(namespace)/\(name)" }
    var revisions: [HelmRevision] { [latest] + older }

    func matches(_ needle: String) -> Bool {
        let haystack = [
            name, namespace, latest.chartLabel, latest.appVersion, latest.status, latest.description,
        ]
        return haystack.contains { $0.range(of: needle, options: .caseInsensitive) != nil }
    }
}

// MARK: - Loading and decoding

enum HelmLoader {
    static let secretType = "helm.sh/release.v1"

    struct SecretListFetch: Sendable {
        var namespace: String
        var list: JSONValue?
        var failure: String?
    }

    /// How many namespace listings may be in flight at once. A cluster can have
    /// hundreds of namespaces and the picker allows selecting every one of them,
    /// so the fan-out is windowed rather than opening a request per namespace.
    private static let maximumConcurrentLists = 6

    /// One request per selected namespace, or a single cluster-wide request when
    /// no namespace filter is active.
    static func listSecrets(client: KubeClient, namespaces: [String]?) async -> [SecretListFetch] {
        var scopes: [String?] = [nil]
        if let namespaces, !namespaces.isEmpty {
            scopes = namespaces.map { name -> String? in name }
        }
        return await withTaskGroup(of: SecretListFetch.self) { group in
            var pending = scopes.makeIterator()
            var started = 0
            while started < maximumConcurrentLists, let scope = pending.next() {
                started += 1
                group.addTask { await fetch(client: client, namespace: scope) }
            }
            var collected: [SecretListFetch] = []
            collected.reserveCapacity(scopes.count)
            while let result = await group.next() {
                collected.append(result)
                if let scope = pending.next() {
                    group.addTask { await fetch(client: client, namespace: scope) }
                }
            }
            return collected
        }
    }

    private static func fetch(client: KubeClient, namespace: String?) async -> SecretListFetch {
        do {
            let list = try await list(client: client, namespace: namespace)
            return SecretListFetch(namespace: namespace ?? "", list: list)
        } catch {
            return SecretListFetch(namespace: namespace ?? "", failure: describe(error))
        }
    }

    private static func list(client: KubeClient, namespace: String?) async throws -> JSONValue {
        let path: String
        if let namespace, !namespace.isEmpty {
            path = "/api/v1/namespaces/\(namespace)/secrets"
        } else {
            path = "/api/v1/secrets"
        }
        return try await client.get(path: path, query: [
            URLQueryItem(name: "fieldSelector", value: "type=\(secretType)"),
            URLQueryItem(name: "limit", value: "1000"),
        ])
    }

    static func describe(_ error: Error) -> String {
        if let status = error as? KubeStatusError { return status.errorDescription ?? "HTTP \(status.code)" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func releases(from lists: [JSONValue]) -> [HelmRelease] {
        let revisions = lists.flatMap { $0.array(at: "items") }.compactMap(revision(from:))
        var grouped: [String: [HelmRevision]] = [:]
        for revision in revisions {
            grouped["\(revision.namespace)/\(revision.releaseName)", default: []].append(revision)
        }
        return grouped.values.compactMap { group -> HelmRelease? in
            let sorted = group.sorted { $0.revision > $1.revision }
            guard let newest = sorted.first else { return nil }
            // Manifests are large and only the current one is ever shown, so the
            // superseded copies are dropped rather than held for the session.
            var older = Array(sorted.dropFirst())
            for index in older.indices {
                older[index].manifest = ""
                older[index].notes = ""
            }
            return HelmRelease(
                name: newest.releaseName, namespace: newest.namespace, latest: newest, older: older
            )
        }
        .sorted { ($0.name, $0.namespace) < ($1.name, $1.namespace) }
    }

    static func revision(from secret: JSONValue) -> HelmRevision? {
        guard let encoded = secret.string(at: "data.release"),
              let payload = decodePayload(encoded),
              let release = try? JSONParser.parse(payload),
              let name = release.string(at: "name")
        else { return nil }

        let object = KubeObject(secret)
        return HelmRevision(
            releaseName: name,
            namespace: release.string(at: "namespace") ?? object.namespace ?? "",
            revision: release.int(at: "version") ?? 0,
            status: release.string(at: "info.status") ?? "unknown",
            chartName: release.string(at: "chart.metadata.name") ?? "",
            chartVersion: release.string(at: "chart.metadata.version") ?? "",
            appVersion: release.string(at: "chart.metadata.appVersion") ?? "",
            updated: timestamp(release.string(at: "info.last_deployed")),
            description: release.string(at: "info.description") ?? "",
            manifest: release.string(at: "manifest") ?? "",
            notes: release.string(at: "info.notes") ?? "",
            secret: object
        )
    }

    /// The Secret value is base64 (Kubernetes) of base64 (Helm) of gzipped JSON.
    /// Very old releases stored the JSON uncompressed, so each layer is probed
    /// rather than assumed.
    static func decodePayload(_ encoded: String) -> Data? {
        guard let outer = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else { return nil }
        if isGzip(outer) { return Gzip.inflate(outer) }
        if let inner = Data(base64Encoded: outer, options: [.ignoreUnknownCharacters]) {
            if isGzip(inner) { return Gzip.inflate(inner) }
            if inner.first == UInt8(ascii: "{") { return inner }
        }
        return outer.first == UInt8(ascii: "{") ? outer : nil
    }

    private static func isGzip(_ data: Data) -> Bool {
        guard data.count > 2 else { return false }
        let start = data.startIndex
        return data[start] == 0x1f && data[data.index(after: start)] == 0x8b
    }

    /// Helm writes nanosecond precision, which `ISO8601DateFormatter` rejects,
    /// and a year-1 zero date for revisions that were never deployed.
    private static func timestamp(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        var date = KubeDate.parse(text)
        if date == nil, let dot = text.firstIndex(of: ".") {
            let zone = text[dot...].drop { $0 == "." || $0.isNumber }
            date = KubeDate.parse(String(text[..<dot]) + zone)
        }
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

// MARK: - Gzip

/// Apple's `COMPRESSION_ZLIB` decodes raw DEFLATE, so the gzip wrapper Helm
/// writes has to be peeled off before the payload can be handed to it.
enum Gzip {
    private static let maximumSize = 64 * 1024 * 1024

    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        // 10-byte header + 8-byte trailer, plus at least one byte of payload.
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }

        let flags = bytes[3]
        var cursor = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard cursor + 2 <= bytes.count else { return nil }
            cursor += 2 + (Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8))
        }
        if flags & 0x08 != 0 {  // FNAME
            guard let next = skipCString(bytes, from: cursor) else { return nil }
            cursor = next
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            guard let next = skipCString(bytes, from: cursor) else { return nil }
            cursor = next
        }
        if flags & 0x02 != 0 { cursor += 2 }  // FHCRC

        let end = bytes.count - 8
        guard cursor > 0, cursor < end else { return nil }
        var isize = 0
        for offset in 0..<4 { isize |= Int(bytes[end + 4 + offset]) << (8 * offset) }
        return decode(Data(bytes[cursor..<end]), hint: isize)
    }

    private static func skipCString(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0 { return index + 1 }
            index += 1
        }
        return nil
    }

    private static func decode(_ deflated: Data, hint: Int) -> Data? {
        // ISIZE is only 32 bits and comes from the file itself, so it seeds the
        // buffer rather than sizing it: a corrupt trailer is first clamped to
        // what this much DEFLATE input could plausibly expand to (the format
        // tops out near 1032:1) so a bogus length cannot demand a huge
        // allocation, and the buffer is still grown until the stream fits. The
        // extra byte keeps an exactly-sized guess distinguishable from a
        // truncation.
        let plausible = deflated.count < maximumSize / 1100 ? deflated.count * 1100 : maximumSize
        let lowerBound = deflated.count < maximumSize / 4 ? deflated.count * 4 : maximumSize
        var capacity = min(max(min(hint, plausible), lowerBound, 64 * 1024) + 1, maximumSize)
        while true {
            var output = Data(count: capacity)
            let size = capacity
            let written = output.withUnsafeMutableBytes { destination -> Int in
                guard let target = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return deflated.withUnsafeBytes { source -> Int in
                    guard let origin = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        target, size, origin, deflated.count, nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written == 0 { return nil }
            if written < capacity { return Data(output.prefix(written)) }
            guard capacity < maximumSize else { return nil }
            capacity = min(capacity * 2, maximumSize)
        }
    }
}
