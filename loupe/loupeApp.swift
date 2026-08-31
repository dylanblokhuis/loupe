//
//  loupeApp.swift
//  loupe
//

import SwiftUI

@main
struct loupeApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("Reload Kubeconfig") { model.reloadConfig() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            SidebarCommands()
        }

        WindowGroup(for: LogsWindowRequest.self) { $request in
            if let request {
                LogsWindow(request: request)
                    .environment(model)
                    .frame(minWidth: 640, minHeight: 400)
            }
        }
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }
    }
}
