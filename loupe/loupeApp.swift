//
//  loupeApp.swift
//  loupe
//

import AppKit
import SwiftUI

/// macOS keeps an app running after its last window closes. Loupe is a
/// document-less browser — once the windows are gone there is nothing to
/// come back to, so we quit instead of lingering in the Dock.
///
/// SwiftUI's Settings scene also leaves a hidden `NSPanel` around after
/// the first open, which would otherwise prevent the last-window-closed
/// hook from ever firing; the close observer covers that case.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        DispatchQueue.main.async {
            let stillOpen = NSApp.windows.contains { window in
                window !== closing && AppDelegate.isUserWindow(window)
            }
            if !stillOpen {
                NSApp.terminate(nil)
            }
        }
    }

    /// Settings is an NSPanel that SwiftUI keeps around after first open.
    private static func isUserWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.canBecomeMain && !(window is NSPanel)
    }
}

@main
struct loupeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
