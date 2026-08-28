import SwiftUI
import UniformTypeIdentifiers

/// Streams a container's logs, with the controls `kubectl logs` exposes as
/// flags: container, follow, previous, tail length, timestamps.
struct PodLogsView: View {
    let connection: ClusterConnection
    let pod: KubeObject
    /// True when this view is already a standalone log window, which hides
    /// the open-in-new-window button.
    var isDetached = false

    @Environment(\.openWindow) private var openWindow

    @State private var container: String = ""
    @State private var follow = true
    @State private var previous = false
    @State private var timestamps = false
    @State private var wrap = false
    @State private var tailLines = 500
    @State private var filter = ""
    @State private var lines: [LogLine] = []
    @State private var errorMessage: String?
    @State private var isStreaming = false
    @State private var autoScroll = true
    @State private var accumulator = LineAccumulator()
    /// SwiftUI can run `.task` twice for one appearance; the token stops the
    /// cancelled run's teardown from clearing the live run's state.
    @State private var runToken = 0

    private static let maximumLines = 20_000

    private var containers: [String] {
        let main = pod.raw.array(at: "spec.containers").compactMap { $0.string(at: "name") }
        let initial = pod.raw.array(at: "spec.initContainers").compactMap { $0.string(at: "name") }
        return main + initial
    }

    private var filtered: [LogLine] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.text.lowercased().contains(needle) }
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
        let longest = filtered.suffix(2_000).map(\.text.count).max() ?? 0
        return 24 + CGFloat(min(longest, 4_000)) * 6.63
    }

    private var streamKey: String {
        "\(pod.id)|\(container)|\(follow)|\(previous)|\(timestamps)|\(tailLines)"
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $container) {
                ForEach(containers, id: \.self) { Text($0).tag($0) }
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

            Spacer()

            if !isDetached, let namespace = pod.namespace {
                Button {
                    openWindow(value: PodLogsWindowRequest(
                        contextName: connection.target.contextName,
                        namespace: namespace,
                        podName: pod.name
                    ))
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Open logs in a new window")
            }

            Button {
                ResourceActions.copyToPasteboard(filtered.map(\.text).joined(separator: "\n"))
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
        .onAppear {
            if container.isEmpty { container = containers.first ?? "" }
        }
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.tint)
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

    private var statusBar: some View {
        HStack(spacing: 8) {
            if isStreaming {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("streaming").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("stopped").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("\(filtered.count) lines").font(.system(size: 10)).foregroundStyle(.secondary)
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

    // MARK: Streaming

    /// Runs inside `.task(id:)` so SwiftUI owns cancellation: switching
    /// container, toggling follow, or closing the inspector tears the stream
    /// down without any bookkeeping of our own.
    private func stream() async {
        guard let client = connection.client, let namespace = pod.namespace, !container.isEmpty else { return }

        lines = []
        accumulator.pending = []
        accumulator.nextIndex = 0
        errorMessage = nil
        var query = [
            URLQueryItem(name: "container", value: container),
            URLQueryItem(name: "tailLines", value: String(tailLines)),
        ]
        if follow { query.append(URLQueryItem(name: "follow", value: "true")) }
        if previous { query.append(URLQueryItem(name: "previous", value: "true")) }
        if timestamps { query.append(URLQueryItem(name: "timestamps", value: "true")) }

        // The log endpoint negotiates like any other: a `text/plain` Accept is
        // rejected outright, so the standard client-go header is used instead.
        var request = KubeRequest.get("/api/v1/namespaces/\(namespace)/pods/\(pod.name)/log", query: query)
        request.accept = "application/json, */*"

        runToken += 1
        let token = runToken
        isStreaming = true
        defer {
            flush()
            if token == runToken { isStreaming = false }
        }

        // A reader fills an unobserved buffer while a ticker drains it, so a
        // chatty container cannot drive one SwiftUI update per line — and a
        // quiet one still shows its last partial batch.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    flush()
                }
            }
            group.addTask { @MainActor in
                do {
                    for try await line in client.lines(request) {
                        accumulator.pending.append(line)
                    }
                } catch {
                    if !Task.isCancelled { errorMessage = ClusterConnection.describe(error) }
                }
            }
            // The reader finishing ends the stream; stop the ticker with it.
            await group.next()
            group.cancelAll()
        }
    }

    private func flush() {
        guard !accumulator.pending.isEmpty else { return }
        let batch = accumulator.pending
        accumulator.pending.removeAll(keepingCapacity: true)
        let start = accumulator.nextIndex
        accumulator.nextIndex += batch.count
        append(batch.enumerated().map { LogLine(index: start + $0.offset, text: $0.element) })
    }

    private func append(_ newLines: [LogLine]) {
        lines.append(contentsOf: newLines)
        if lines.count > Self.maximumLines {
            lines.removeFirst(lines.count - Self.maximumLines)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pod.name)-\(container).log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? filtered.map(\.text).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Plain reference storage so filling the buffer does not invalidate the
    /// view on every line.
    @MainActor
    final class LineAccumulator {
        var pending: [String] = []
        /// Monotonic, so ids stay unique after the ring buffer drops the head.
        var nextIndex = 0
    }

    struct LogLine: Identifiable {
        let index: Int
        let text: String
        var id: Int { index }

        /// Tints obvious severities so errors stand out while scrolling.
        var tint: Color {
            let lowered = text.lowercased()
            if lowered.contains("error") || lowered.contains(" err ") || lowered.contains("fatal")
                || lowered.contains("panic") || lowered.contains("\"level\":\"error\"") {
                return .red
            }
            if lowered.contains("warn") { return .orange }
            if lowered.contains("debug") || lowered.contains("trace") { return .secondary }
            return .primary
        }
    }
}
