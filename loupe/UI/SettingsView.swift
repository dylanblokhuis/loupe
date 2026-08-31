import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            KubeconfigSettings()
                .tabItem { Label("Kubeconfig", systemImage: "doc.badge.gearshape") }
            MetricsSettingsView()
                .tabItem { Label("Metrics", systemImage: "waveform.path.ecg") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 420)
    }
}

struct KubeconfigSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Files") {
                if model.configPaths.isEmpty {
                    Text("No kubeconfig files configured.")
                } else {
                    ForEach(model.configPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: FileManager.default.fileExists(atPath: path.path)
                                ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(FileManager.default.fileExists(atPath: path.path)
                                    ? Color.green : Color.secondary)
                            Text(path.path)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([path])
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                Text("Set the KUBECONFIG environment variable to point Loupe at other files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Contexts") {
                LabeledContent("Discovered", value: "\(model.config.contexts.count)")
                LabeledContent("Current", value: model.config.currentContext ?? "—")
                LabeledContent("Connected", value: "\(model.connections.count)")
                Button("Reload Kubeconfig") { model.reloadConfig() }
            }

            if let error = model.configError {
                Section("Problem") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct UpdateSettings: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section("Version") {
                LabeledContent("Installed", value: Updater.installedVersion)
                LabeledContent("Last checked", value: lastChecked)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }

            Section("Automatic") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download updates in the background", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                Text("Updates are published as GitHub releases and refused unless they carry "
                     + "Loupe's own signature, so an update is only ever the build that came out "
                     + "of the project's release workflow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lastChecked: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sailboat.circle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tint)
            Text("Loupe").font(.title2.weight(.semibold))
            Text("A SwiftUI Kubernetes cluster browser.")
                .foregroundStyle(.secondary)
            Text("Resources are listed through the Kubernetes Table API, so every kind the "
                 + "cluster serves — including custom resources — is browsable with the same "
                 + "columns kubectl prints.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
