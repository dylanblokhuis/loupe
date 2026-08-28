import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            KubeconfigSettings()
                .tabItem { Label("Kubeconfig", systemImage: "doc.badge.gearshape") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 340)
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
