import SwiftUI

/// Events involving a single object, newest first and kept live.
struct ObjectEventsView: View {
    let connection: ClusterConnection
    let object: KubeObject

    @State private var events: [KubeObject] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading, events.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, events.isEmpty {
                EmptyStateView(title: "Could not load events", message: errorMessage,
                               systemImage: "exclamationmark.triangle")
            } else if events.isEmpty {
                EmptyStateView(title: "No events", message: "Nothing has happened to this object recently.",
                               systemImage: "bell.slash")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            EventRow(event: event, showsInvolvedObject: false)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: object.id) { await load() }
    }

    private func load() async {
        guard let client = connection.client else { return }
        isLoading = true
        defer { isLoading = false }
        // The uid selector is exact; the name selector catches events recorded
        // before the object was recreated with the same name.
        let selector = object.uid.isEmpty
            ? "involvedObject.name=\(object.name)"
            : "involvedObject.uid=\(object.uid)"
        let path = object.namespace.map { "/api/v1/namespaces/\($0)/events" } ?? "/api/v1/events"
        do {
            let result = try await client.get(
                path: path,
                query: [
                    URLQueryItem(name: "fieldSelector", value: selector),
                    URLQueryItem(name: "limit", value: "200"),
                ]
            )
            events = result.array(at: "items").map(KubeObject.init).sorted {
                EventRow.timestamp(of: $0) > EventRow.timestamp(of: $1)
            }
            errorMessage = nil
        } catch {
            errorMessage = ClusterConnection.describe(error)
        }
    }
}

struct EventRow: View {
    let event: KubeObject
    var showsInvolvedObject = true
    var onSelect: (() -> Void)?

    private var isWarning: Bool { event.raw.string(at: "type") == "Warning" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(isWarning ? Color.orange : Color.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.raw.string(at: "reason") ?? "—")
                        .font(.system(size: 11, weight: .semibold))
                    if showsInvolvedObject {
                        Text("\(event.raw.string(at: "involvedObject.kind") ?? "")/"
                             + "\(event.raw.string(at: "involvedObject.name") ?? "")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if let count = event.raw.int(at: "count"), count > 1 {
                        Chip(text: "×\(count)", color: .secondary)
                    }
                    Text(Age.short(since: EventRow.timestamp(of: event)))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(Age.absolute(EventRow.timestamp(of: event)))
                }
                Text(event.raw.string(at: "message") ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
    }

    /// Events carry three different timestamp fields depending on the API that
    /// recorded them.
    static func timestamp(of event: KubeObject) -> Date {
        KubeDate.parse(event.raw.string(at: "lastTimestamp"))
            ?? KubeDate.parse(event.raw.string(at: "eventTime"))
            ?? KubeDate.parse(event.raw.string(at: "firstTimestamp"))
            ?? event.creationTimestamp
            ?? .distantPast
    }
}
