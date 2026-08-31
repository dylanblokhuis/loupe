import SwiftUI
import UniformTypeIdentifiers

/// What a log console is attached to.
enum LogScope: Equatable {
    case pod(KubeObject)
    /// Every pod behind a controller — a Deployment, StatefulSet, Job, …
    case workload(KubeObject)

    var object: KubeObject {
        switch self {
        case .pod(let object), .workload(let object): return object
        }
    }

    var isWorkload: Bool {
        if case .workload = self { return true }
        return false
    }

    /// Picks the right scope for an object, so callers do not each have to know
    /// which kinds can be fanned out.
    static func best(for object: KubeObject) -> LogScope? {
        if object.kind == "Pod" { return .pod(object) }
        return WorkloadPods.supports(object) ? .workload(object) : nil
    }
}

/// Streams container logs, with the controls `kubectl logs` exposes as flags:
/// container, follow, previous, tail length, timestamps.
///
/// For a workload scope it does what `kubectl logs deployment/x` cannot: every
/// pod behind the controller is streamed at once and the lines are merged, so
/// a rollout or a three-replica service reads as one log.
struct LogsView: View {
    let connection: ClusterConnection
    let scope: LogScope
    /// True when this view is already a standalone log window, which hides
    /// the open-in-new-window button.
    var isDetached = false

    @Environment(\.openWindow) private var openWindow

    @State private var containerSelection: ContainerSelection
    @State private var follow = true
    @State private var previous = false
    @State private var timestamps = false
    @State private var wrap = false
    @State private var tailLines = 500
    /// How many pods of a workload are streamed at once. Every stream is its
    /// own long-lived connection to the API server, so this is a real cost and
    /// not just a display limit.
    @State private var podLimit = 10
    @State private var filter = ""
    @State private var lines: [LogLine] = []
    @State private var sources: [LogSource] = []
    @State private var hiddenSources: Set<Int> = []
    @State private var podsFound = 0
    @State private var errorMessage: String?
    @State private var isStreaming = false
    @State private var autoScroll = true
    @State private var accumulator = LineAccumulator()
    /// SwiftUI can run `.task` twice for one appearance; the token stops the
    /// cancelled run's teardown from clearing the live run's state.
    @State private var runToken = 0

    private static let maximumLines = 20_000

    init(connection: ClusterConnection, scope: LogScope, isDetached: Bool = false) {
        self.connection = connection
        self.scope = scope
        self.isDetached = isDetached
        // Defaulting to every container would drown a pod that has sidecars, so
        // the first container is preselected exactly as `kubectl logs` does.
        let containers = WorkloadPods.templateContainers(of: scope.object)
        _containerSelection = State(
            wrappedValue: containers.first.map(ContainerSelection.named) ?? .all
        )
    }

    enum ContainerSelection: Hashable {
        case all
        case named(String)

        var key: String {
            switch self {
            case .all: return "*"
            case .named(let name): return name
            }
        }

        var label: String {
            switch self {
            case .all: return "All containers"
            case .named(let name): return name
            }
        }
    }

    private var containers: [String] { WorkloadPods.templateContainers(of: scope.object) }

    private var visibleSources: [LogSource] {
        sources.enumerated().filter { !hiddenSources.contains($0.offset) }.map(\.element)
    }

    private var filtered: [LogLine] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty || !hiddenSources.isEmpty else { return lines }
        return lines.filter { line in
            guard !hiddenSources.contains(line.source) else { return false }
            guard !needle.isEmpty else { return true }
            return line.text.lowercased().contains(needle)
        }
    }

    /// The pod column only earns its width once more than one thing is being
    /// streamed.
    private var showsSourceColumn: Bool { sources.count > 1 }

    private var sourceColumnWidth: Int {
        min(38, sources.map(\.label.count).max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let errorMessage {
                Banner(message: errorMessage, tint: .red) { self.errorMessage = nil }
            }
            logBody
            Divider()
            statusBar
        }
        .task(id: streamKey) { await stream() }
    }

    private var contentWidth: CGFloat {
        let prefix = (showsSourceColumn ? sourceColumnWidth + 1 : 0) + (timestamps ? 25 : 0)
        let longest = filtered.suffix(2_000).map(\.text.count).max() ?? 0
        return 24 + CGFloat(min(longest + prefix, 4_000)) * 6.63
    }

    private var streamKey: String {
        "\(scope.object.id)|\(containerSelection.key)|\(follow)|\(previous)|\(tailLines)|\(podLimit)"
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $containerSelection) {
                Text("All containers").tag(ContainerSelection.all)
                Divider()
                ForEach(containers, id: \.self) { Text($0).tag(ContainerSelection.named($0)) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)

            Divider().frame(height: 14)

            Toggle("Follow", isOn: $follow).toggleStyle(.button).controlSize(.small)
            Toggle("Previous", isOn: $previous).toggleStyle(.button).controlSize(.small)
                .help("Show logs from the previous container instance")
            Toggle("Timestamps", isOn: $timestamps).toggleStyle(.button).controlSize(.small)
            Toggle("Wrap", isOn: $wrap).toggleStyle(.button).controlSize(.small)

            Menu {
                ForEach([100, 500, 1000, 5000, 10000], id: \.self) { count in
                    Button("\(count) lines") { tailLines = count }
                }
            } label: {
                Text("Tail \(tailLines)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if scope.isWorkload {
                Menu {
                    Section("Pods streamed at once") {
                        ForEach([3, 10, 25, 50], id: \.self) { count in
                            Button("\(count) pods") { podLimit = count }
                        }
                    }
                } label: {
                    Text("Max \(podLimit)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Each pod is streamed over its own connection to the API server.")
            }

            Spacer()

            if sources.count > 1 { sourcesMenu }

            if !isDetached, let namespace = scope.object.namespace {
                Button {
                    openWindow(value: LogsWindowRequest(
                        contextName: connection.target.contextName,
                        namespace: namespace,
                        kind: scope.object.kind.isEmpty ? "Pod" : scope.object.kind,
                        name: scope.object.name
                    ))
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Open logs in a new window")
            }

            Button {
                ResourceActions.copyToPasteboard(exportText)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy visible logs")

            Button {
                save()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Save logs to a file")

            Button {
                lines = []
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var sourcesMenu: some View {
        Menu {
            Button("Show All") { hiddenSources = [] }
                .disabled(hiddenSources.isEmpty)
            Divider()
            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                Toggle(isOn: Binding(
                    get: { !hiddenSources.contains(index) },
                    set: { shown in
                        if shown { hiddenSources.remove(index) } else { hiddenSources.insert(index) }
                    }
                )) {
                    Text(source.error == nil
                         ? "\(source.label) — \(source.lineCount) lines"
                         : "\(source.label) — \(source.error ?? "")")
                }
            }
        } label: {
            Label("\(visibleSources.count)/\(sources.count)", systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which pods are being shown")
    }

    // MARK: Log body

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { line in
                        styled(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: !wrap, vertical: false)
                            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 0.5)
                            .id(line.id)
                    }
                    Color.clear.frame(width: 1, height: 1).id("bottom")
                }
                .padding(.vertical, 6)
                // Wrapped lines fill the pane; unwrapped ones need a definite
                // width for the horizontal scroll view to lay out against.
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .frame(width: wrap ? nil : contentWidth, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: filtered.count) { _, _ in
                guard autoScroll else { return }
                // Anchor on the leading edge so following the tail does not
                // also drag the horizontal scroll to the centre of long lines.
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("bottom", anchor: UnitPoint(x: 0, y: 1))
                }
            }
        }
    }

    /// One line as a single `Text` so the list stays one view per line — and so
    /// a selection can run across the whole line: a dimmed timestamp, the pod's
    /// colour-coded name, then the message.
    private func styled(_ line: LogLine) -> Text {
        var result = AttributedString()
        if timestamps, !line.stamp.isEmpty {
            var stamp = AttributedString(LogLine.displayStamp(line.stamp) + " ")
            stamp.foregroundColor = .secondary
            result += stamp
        }
        if showsSourceColumn, sources.indices.contains(line.source) {
            let source = sources[line.source]
            var label = AttributedString(source.padded(to: sourceColumnWidth) + " ")
            label.foregroundColor = source.color
            result += label
        }
        var body = AttributedString(line.text)
        body.foregroundColor = line.tint
        result += body
        return Text(result)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if isStreaming {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("streaming").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("stopped").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("\(filtered.count) lines").font(.system(size: 10)).foregroundStyle(.secondary)
            if scope.isWorkload, podsFound > 0 {
                Text(podsFound > podLimit
                     ? "first \(podLimit) of \(podsFound) pods"
                     : "\(podsFound) pod\(podsFound == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(podsFound > podLimit ? .orange : .secondary)
                    .help(podsFound > podLimit
                          ? "Raise the pod limit in the toolbar to stream the rest."
                          : "Pods matching this controller's selector")
            }
            if failingSources > 0 {
                Text("\(failingSources) failing")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(sources.compactMap(\.error).first ?? "")
            }
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 9))
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .frame(maxWidth: 220)
            }
            Spacer()
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var failingSources: Int { sources.count { $0.error != nil } }

    // MARK: Streaming

    /// Runs inside `.task(id:)` so SwiftUI owns cancellation: switching
    /// container, toggling follow, or closing the inspector tears every stream
    /// down without any bookkeeping of our own.
    private func stream() async {
        guard let client = connection.client else { return }

        lines = []
        sources = []
        hiddenSources = []
        podsFound = 0
        accumulator.reset()
        errorMessage = nil

        runToken += 1
        let token = runToken
        isStreaming = true
        defer {
            // Cancellation is not synchronous, so a superseded run can reach
            // here after its replacement has already reset the buffer; its
            // last batch belongs to a stream nothing is showing any more.
            if token == runToken {
                flush()
                isStreaming = false
            }
        }

        // A reader fills an unobserved buffer while a ticker drains it, so a
        // chatty container cannot drive one SwiftUI update per line — and a
        // quiet one still shows its last partial batch.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                // The first drain waits longer so the initial tails of every
                // pod land in one batch and can be merged in timestamp order.
                var first = true
                while !Task.isCancelled {
                    try? await Task.sleep(for: first ? .milliseconds(700) : .milliseconds(120))
                    first = false
                    flush()
                }
            }
            group.addTask { @MainActor in await runStreams(client: client) }
            // The readers finishing ends the stream; stop the ticker with it.
            await group.next()
            group.cancelAll()
        }
    }

    /// Discovers what to stream and keeps streaming it. For a workload the
    /// discovery repeats, so pods created by a rollout join the log on their
    /// own.
    @MainActor
    private func runStreams(client: KubeClient) async {
        await withTaskGroup(of: Void.self) { group in
            var started: Set<String> = []
            while !Task.isCancelled {
                var pods: [KubeObject] = []
                switch scope {
                case .pod(let pod):
                    pods = [pod]
                    podsFound = 1
                case .workload(let workload):
                    do {
                        let resolved = try await WorkloadPods.resolve(client: client, workload: workload)
                        podsFound = resolved.count
                        pods = Array(resolved.prefix(podLimit))
                        // Only ever touched before the first stream starts, so
                        // rediscovery cannot wipe a real streaming error.
                        if started.isEmpty {
                            errorMessage = resolved.isEmpty
                                ? "No pods match this \(workload.kind)'s selector."
                                : nil
                        }
                    } catch {
                        if started.isEmpty { errorMessage = ClusterConnection.describe(error) }
                    }
                }

                for pod in pods {
                    for container in containerNames(of: pod) {
                        // Keyed by UID: a StatefulSet pod that is replaced keeps
                        // its name, and its new instance does need a new stream.
                        let key = "\(pod.uid.isEmpty ? pod.name : pod.uid)/\(container)"
                        guard started.insert(key).inserted else { continue }
                        let index = addSource(pod: pod.name, container: container)
                        group.addTask { @MainActor in
                            await streamOne(client: client, pod: pod, container: container, source: index)
                        }
                    }
                }

                guard follow, scope.isWorkload else { break }
                try? await Task.sleep(for: .seconds(10))
            }
            await group.waitForAll()
        }
    }

    private func containerNames(of pod: KubeObject) -> [String] {
        switch containerSelection {
        case .named(let name): return [name]
        case .all:
            let names = WorkloadPods.templateContainers(of: pod)
            return names.isEmpty ? containers : names
        }
    }

    private func addSource(pod: String, container: String) -> Int {
        let label = containerSelection == .all && containers.count > 1
            ? "\(pod)/\(container)"
            : pod
        sources.append(LogSource(
            label: label, color: LogSource.palette[sources.count % LogSource.palette.count]
        ))
        return sources.count - 1
    }

    /// Streams one container. A stream that ends cleanly is not restarted — the
    /// container exited, exactly as `kubectl logs -f` would stop.
    @MainActor
    private func streamOne(client: KubeClient, pod: KubeObject, container: String, source: Int) async {
        guard let namespace = pod.namespace ?? scope.object.namespace else { return }
        var query = [
            URLQueryItem(name: "container", value: container),
            URLQueryItem(name: "tailLines", value: String(tailLines)),
            // Always requested, shown only on demand: the kubelet's timestamps
            // are what several pods' lines are merged on.
            URLQueryItem(name: "timestamps", value: "true"),
        ]
        if follow { query.append(URLQueryItem(name: "follow", value: "true")) }
        if previous { query.append(URLQueryItem(name: "previous", value: "true")) }

        // The log endpoint negotiates like any other: a `text/plain` Accept is
        // rejected outright, so the standard client-go header is used instead.
        var request = KubeRequest.get("/api/v1/namespaces/\(namespace)/pods/\(pod.name)/log", query: query)
        request.accept = "application/json, */*"

        var attempt = 0
        var received = false
        while !Task.isCancelled {
            do {
                for try await line in client.lines(request) {
                    if !received {
                        received = true
                        setError(source, nil)
                    }
                    accumulator.append(source: source, raw: line)
                }
                return
            } catch {
                if Task.isCancelled { return }
                let message = ClusterConnection.describe(error)
                setError(source, message)
                if sources.count == 1 { errorMessage = message }
                // Only a source that has produced nothing is retried: a
                // container that has not started yet fails immediately, while
                // re-requesting one that already streamed would replay lines
                // that are on screen.
                guard !received, follow, attempt < 40 else { return }
                attempt += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func setError(_ source: Int, _ message: String?) {
        guard sources.indices.contains(source) else { return }
        sources[source].error = message
    }

    // MARK: Buffering

    private func flush() {
        let batch = accumulator.take()
        guard !batch.isEmpty else { return }

        // Each source arrives in order already; merging on the kubelet's
        // timestamp is what turns several pods' tails into one chronological
        // log rather than one block per pod. Lines the server did not stamp
        // inherit the last stamp seen from their own source so they stay put.
        var lastStamp: [Int: String] = [:]
        var parsed: [(stamp: String, arrival: Int, line: LogLine)] = []
        parsed.reserveCapacity(batch.count)
        for (offset, entry) in batch.enumerated() {
            var split = LogLine.split(entry.raw)
            if split.stamp.isEmpty {
                split.stamp = lastStamp[entry.source] ?? ""
            } else {
                lastStamp[entry.source] = split.stamp
            }
            parsed.append((
                split.stamp, offset,
                LogLine(index: 0, source: entry.source, stamp: split.stamp, text: split.text)
            ))
        }
        // RFC3339 UTC sorts lexicographically, so no date parsing is needed;
        // the arrival index keeps the sort stable for equal stamps.
        parsed.sort { ($0.stamp, $0.arrival) < ($1.stamp, $1.arrival) }

        let start = accumulator.nextIndex
        accumulator.nextIndex += parsed.count
        var appended: [LogLine] = []
        appended.reserveCapacity(parsed.count)
        for (offset, entry) in parsed.enumerated() {
            var line = entry.line
            line.index = start + offset
            appended.append(line)
            if sources.indices.contains(line.source) { sources[line.source].lineCount += 1 }
        }
        lines.append(contentsOf: appended)
        if lines.count > Self.maximumLines {
            lines.removeFirst(lines.count - Self.maximumLines)
        }
    }

    // MARK: Export

    private var exportText: String {
        filtered.map { line in
            var text = ""
            if timestamps, !line.stamp.isEmpty { text += line.stamp + " " }
            if showsSourceColumn, sources.indices.contains(line.source) {
                text += sources[line.source].label + " "
            }
            return text + line.text
        }
        .joined(separator: "\n")
    }

    private func save() {
        let panel = NSSavePanel()
        let suffix: String
        switch containerSelection {
        case .all: suffix = "all"
        case .named(let name): suffix = name
        }
        panel.nameFieldStringValue = "\(scope.object.name)-\(suffix).log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportText.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Plain reference storage so filling the buffer does not invalidate the
    /// view on every line.
    @MainActor
    final class LineAccumulator {
        struct Entry {
            var source: Int
            var raw: String
        }

        private var pending: [Entry] = []
        /// Monotonic, so ids stay unique after the ring buffer drops the head.
        var nextIndex = 0

        func append(source: Int, raw: String) {
            pending.append(Entry(source: source, raw: raw))
        }

        func take() -> [Entry] {
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }

        func reset() {
            pending.removeAll(keepingCapacity: true)
            nextIndex = 0
        }
    }
}
