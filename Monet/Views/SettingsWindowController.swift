import SwiftUI
import AppKit

/// Controller for managing the Settings window
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func showSettings(viewModel: UsageViewModel, authService: AuthenticationService) {
        // If window exists and is visible, just bring it to front
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create the settings view
        let settingsView = SettingsView(viewModel: viewModel)
            .environmentObject(authService)

        // Create the window
        let hostingController = NSHostingController(rootView: settingsView)
        // Prevent NSHostingController from auto-sizing the window based on SwiftUI's
        // ideal size, which can vary across display configurations and macOS versions
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Monet Settings"
        window.styleMask = [.titled, .closable]
        let windowSize = NSSize(width: 420, height: 640)
        window.setContentSize(windowSize)
        window.contentMinSize = windowSize
        window.contentMaxSize = windowSize
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeSettings() {
        window?.close()
    }
}
