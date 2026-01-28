import SwiftUI

@main
struct MonetApp: App {
    @StateObject private var viewModel = UsageViewModel()
    @StateObject private var authService = AuthenticationService.shared

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(viewModel: viewModel)
                .environmentObject(authService)
        } label: {
            MenuBarIcon(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
