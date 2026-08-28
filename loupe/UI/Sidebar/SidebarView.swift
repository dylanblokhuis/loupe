import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: NavDestination?
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            ContextPicker()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if let connection = model.activeConnection {
                if connection.state.isReady {
                    NamespacePicker(connection: connection)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                Divider()
                navigationList(for: connection)
            } else {
                Spacer()
                Text("No cluster selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func navigationList(for connection: ClusterConnection) -> some View {
        if connection.state.isReady {
            List(selection: $selection) {
                ForEach(filteredGroups(connection.navigation)) { group in
                    if group.subgroups.isEmpty {
                        Section {
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        } header: {
                            Label(group.title, systemImage: group.icon)
                        }
                    } else {
                        Section {
                            ForEach(group.subgroups) { subgroup in
                                DisclosureGroup {
                                    ForEach(subgroup.entries) { entry in
                                        row(entry)
                                    }
                                } label: {
                                    Text(subgroup.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                        } header: {
                            Label(group.title, systemImage: group.icon)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $filter, placement: .sidebar, prompt: "Filter resources")
        } else {
            VStack(spacing: 10) {
                if connection.state.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Connection failed").font(.callout)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Loading resources…").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ entry: NavEntry) -> some View {
        Label(entry.title, systemImage: entry.icon)
            .lineLimit(1)
            .tag(entry.destination)
    }

    private func filteredGroups(_ groups: [NavGroup]) -> [NavGroup] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group -> NavGroup? in
            var copy = group
            copy.entries = group.entries.filter { $0.title.lowercased().contains(needle) }
            copy.subgroups = group.subgroups.compactMap { subgroup in
                var sub = subgroup
                sub.entries = subgroup.entries.filter { $0.title.lowercased().contains(needle) }
                if sub.entries.isEmpty, !subgroup.title.lowercased().contains(needle) { return nil }
                if sub.entries.isEmpty { sub.entries = subgroup.entries }
                return sub
            }
            return copy.isEmpty ? nil : copy
        }
    }
}

struct ContextPicker: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 8) {
                statusIndicator
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.activeConnection?.name ?? "Choose a cluster")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if let connection = model.activeConnection {
                        Text(connection.target.cluster.server)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ContextList { showing = false }
                .environment(model)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let connection = model.activeConnection {
            switch connection.state {
            case .connecting:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            case .ready:
                Circle().fill(.green).frame(width: 8, height: 8)
            case .failed:
                Circle().fill(.red).frame(width: 8, height: 8)
            case .idle:
                Circle().fill(.secondary).frame(width: 8, height: 8)
            }
        } else {
            Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ContextList: View {
    @Environment(AppModel.self) private var model
    var dismiss: () -> Void
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search clusters", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    if !model.connections.isEmpty {
                        Section {
                            ForEach(model.connections) { connection in
                                contextRow(
                                    name: connection.target.contextName,
                                    subtitle: connection.target.cluster.server,
                                    connection: connection
                                )
                            }
                        } header: {
                            sectionHeader("Connected")
                        }
                    }
                    ForEach(model.contextsByFile, id: \.file) { entry in
                        let contexts = entry.contexts.filter(matches)
                        if !contexts.isEmpty {
                            Section {
                                ForEach(contexts) { context in
                                    if !model.isOpen(context.name) {
                                        contextRow(
                                            name: context.name,
                                            subtitle: model.config.cluster(named: context.cluster)?.server
                                                ?? context.cluster,
                                            connection: nil
                                        )
                                    }
                                }
                            } header: {
                                sectionHeader(entry.file.path.replacingOccurrences(
                                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
                                ))
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 420)

            Divider()
            HStack {
                Button {
                    model.reloadConfig()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.caption)
                Spacer()
                Text("\(model.config.contexts.count) contexts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .frame(width: 380)
    }

    private func matches(_ context: KubeContext) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return context.name.lowercased().contains(needle) || context.cluster.lowercased().contains(needle)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
    }

    private func contextRow(name: String, subtitle: String, connection: ClusterConnection?) -> some View {
        HStack(spacing: 8) {
            Group {
                if let connection {
                    switch connection.state {
                    case .ready: Circle().fill(.green)
                    case .failed: Circle().fill(.red)
                    case .connecting: Circle().fill(.yellow)
                    case .idle: Circle().fill(.secondary)
                    }
                } else {
                    Circle().fill(.clear).strokeBorder(.secondary.opacity(0.5))
                }
            }
            .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if name == model.config.currentContext {
                Chip(text: "current", color: .accentColor)
            }
            if let connection {
                Button {
                    model.close(connection)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Disconnect")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(model.activeContextName == name ? Color.accentColor.opacity(0.14) : .clear)
        .onTapGesture {
            model.open(contextNamed: name)
            dismiss()
        }
    }
}

struct NamespacePicker: View {
    let connection: ClusterConnection
    @State private var showing = false
    @State private var search = ""

    private var summary: String {
        let selected = connection.selectedNamespaces
        if selected.isEmpty { return "All namespaces" }
        if selected.count == 1 { return selected.first! }
        return "\(selected.count) namespaces"
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(summary).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            namespaceList
        }
    }

    private var namespaceList: some View {
        @Bindable var connection = connection
        return VStack(spacing: 0) {
            TextField("Search namespaces", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    toggleRow(title: "All namespaces", isOn: connection.selectedNamespaces.isEmpty) {
                        connection.selectedNamespaces = []
                    }
                    Divider().padding(.vertical, 3)
                    ForEach(filtered, id: \.self) { namespace in
                        toggleRow(
                            title: namespace,
                            isOn: connection.selectedNamespaces.contains(namespace)
                        ) {
                            if connection.selectedNamespaces.contains(namespace) {
                                connection.selectedNamespaces.remove(namespace)
                            } else {
                                connection.selectedNamespaces.insert(namespace)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 260)
    }

    private var filtered: [String] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return connection.namespaces }
        return connection.namespaces.filter { $0.lowercased().contains(needle) }
    }

    private func toggleRow(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.system(size: 11))
                Text(title).font(.system(size: 11.5)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
