import SwiftUI
import ServiceManagement

/// Settings view displayed in a separate window
struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @EnvironmentObject var authService: AuthenticationService
    @StateObject private var updateService = UpdateService.shared

    @State private var launchAtLogin: Bool = false
    @State private var showingSignOutAlert = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Settings")
                .font(.system(.title2, weight: .semibold))
                .padding(.bottom, 20)

            // Settings sections
            VStack(spacing: 16) {
                // Display Mode Section
                SettingsSection(title: "Menu Bar Display") {
                    Picker("Display mode", selection: $viewModel.displayMode) {
                        ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.rawValue)
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                // Refresh Interval Section
                SettingsSection(title: "Refresh Interval") {
                    HStack {
                        Slider(
                            value: $viewModel.refreshInterval,
                            in: Constants.Timing.minimumRefreshInterval...Constants.Timing.maximumRefreshInterval,
                            step: 30
                        )
                        Text("\(Int(viewModel.refreshInterval))s")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50)
                            .foregroundColor(.secondary)
                    }
                    Text("How often to fetch usage data from the API")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Launch at Login Section
                SettingsSection(title: "Startup") {
                    Toggle("Launch Monet at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                }

                // Account Section
                SettingsSection(title: "Account") {
                    if case .authenticated(let source) = authService.state {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Signed in")
                                    .font(.body)
                                Text(source == .claudeCode ? "Using Claude Code credentials" : "Using Monet OAuth")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Sign Out") {
                                showingSignOutAlert = true
                            }
                            .foregroundColor(.red)
                        }
                    } else {
                        HStack {
                            Text("Not signed in")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Sign In") {
                                Task {
                                    try? await authService.startOAuthFlow()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // Updates Section
                SettingsSection(title: "Updates") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            switch updateService.status {
                            case .unknown:
                                Text("Update status unknown")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            case .checking:
                                Text("Checking for updates...")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            case .upToDate:
                                Text("Monet is up to date")
                                    .font(.body)
                            case .updateAvailable:
                                if let latest = updateService.latestVersion {
                                    Text("Update available: v\(latest)")
                                        .font(.body)
                                        .foregroundColor(.orange)
                                }
                            case .checkFailed:
                                Text("Unable to check for updates")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            case .downloading:
                                HStack(spacing: 8) {
                                    Text("Downloading update...")
                                        .font(.body)
                                    Text("\(Int(updateService.downloadProgress * 100))%")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }
                            case .installing:
                                Text("Installing update...")
                                    .font(.body)
                                    .foregroundColor(.blue)
                            }
                            if let lastChecked = updateService.lastChecked {
                                Text("Last checked: \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if updateService.status == .downloading || updateService.status == .installing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if updateService.updateAvailable {
                            Button("Install Update") {
                                Task {
                                    await updateService.installUpdate()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Check Now") {
                                Task {
                                    await updateService.checkForUpdates()
                                }
                            }
                            .disabled(updateService.isChecking)
                        }
                    }
                }
            }

            Spacer()

            // Footer with version info
            HStack {
                Text("Monet v\(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 380, height: 600)
        .onAppear {
            loadLaunchAtLoginState()
        }
        .alert("Sign Out", isPresented: $showingSignOutAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Sign Out", role: .destructive) {
                authService.signOut()
            }
        } message: {
            Text("Are you sure you want to sign out? You'll need to sign in again to view usage data.")
        }
    }

    // MARK: - Launch at Login

    private func loadLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                #if DEBUG
                print("Failed to set launch at login: \(error)")
                #endif
            }
        }
    }
}

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    SettingsView(viewModel: UsageViewModel())
        .environmentObject(AuthenticationService.shared)
}
#endif
