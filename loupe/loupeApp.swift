//
//  loupeApp.swift
//  loupe
//

import SwiftUI

@main
struct loupeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Kubeconfig") { model.reloadConfig() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            SidebarCommands()
        }

        WindowGroup(for: PodLogsWindowRequest.self) { $request in
            if let request {
                PodLogsWindow(request: request)
                    .environment(model)
                    .frame(minWidth: 640, minHeight: 400)
            }
        }
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
