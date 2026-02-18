import SwiftUI

/// The main popover panel displaying detailed usage information
struct UsagePanel: View {
    @ObservedObject var viewModel: UsageViewModel
    @EnvironmentObject var authService: AuthenticationService

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                if let error = viewModel.error, error.requiresSubscription {
                    subscriptionRequiredContent
                } else if let error = viewModel.error, error.isScopeError {
                    scopeErrorContent
                } else if viewModel.isAuthenticated {
                    authenticatedContent
                } else {
                    unauthenticatedContent
                }
            }
            .padding(20)
        }
        .frame(width: 340)
    }

    // MARK: - Authenticated Content

    @ViewBuilder
    private var authenticatedContent: some View {
        // Header
        headerView
            .padding(.bottom, 20)

        // Current Session Card
        UsageCard {
            if let session = viewModel.sessionUsage {
                UsageRow(
                    title: "Current session",
                    subtitle: formatSessionSubtitle(session),
                    percentage: session.utilization,
                    color: colorForUsage(session.utilization)
                )
            } else if viewModel.isLoading {
                loadingRow(title: "Current session")
            }
        }

        Spacer().frame(height: 16)

        // Weekly Limits Section
        weeklyLimitsSection
            .padding(.bottom, 12)

        // Weekly usage cards
        UsageCard {
            VStack(spacing: 16) {
                // All Models
                if let weekly = viewModel.weeklyUsage {
                    UsageRow(
                        title: "All models",
                        subtitle: formatWeeklySubtitle(weekly),
                        percentage: weekly.utilization,
                        color: colorForUsage(weekly.utilization)
                    )
                } else if viewModel.isLoading {
                    loadingRow(title: "All models")
                }

                // Sonnet Only
                if let sonnet = viewModel.sonnetUsage {
                    Divider()
                    UsageRow(
                        title: "Sonnet only",
                        subtitle: sonnet.utilization > 0
                            ? formatWeeklySubtitle(sonnet)
                            : "You haven't used Sonnet yet",
                        percentage: sonnet.utilization,
                        color: .teal
                    )
                }

                // Opus Only
                if let opus = viewModel.opusUsage {
                    Divider()
                    UsageRow(
                        title: "Opus only",
                        subtitle: opus.utilization > 0
                            ? formatWeeklySubtitle(opus)
                            : "You haven't used Opus yet",
                        percentage: opus.utilization,
                        color: .purple
                    )
                }
            }
        }

        Spacer().frame(height: 16)

        // Footer
        footerView

        Spacer().frame(height: 12)

        // Actions
        actionsView
    }

    // MARK: - Header View

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Plan Usage")
                    .font(.system(.headline, weight: .semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var statusText: String {
        if viewModel.hasCriticalUsage {
            return "Critical usage level"
        } else if viewModel.hasWarningUsage {
            return "Approaching limits"
        } else {
            return "All systems normal"
        }
    }

    private var statusColor: Color {
        if viewModel.hasCriticalUsage {
            return .red
        } else if viewModel.hasWarningUsage {
            return .orange
        } else {
            return .green
        }
    }

    // MARK: - Weekly Limits Section Header

    @ViewBuilder
    private var weeklyLimitsSection: some View {
        HStack {
            Text("Weekly Limits")
                .font(.system(.subheadline, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Link(destination: URL(string: "https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits")!) {
                HStack(spacing: 4) {
                    Text("Learn more")
                    Image(systemName: "arrow.up.right")
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Unauthenticated Content

    @ViewBuilder
    private var unauthenticatedContent: some View {
        VStack(spacing: 20) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Color(.controlBackgroundColor))
                    .frame(width: 80, height: 80)

                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                Text("Sign in to Claude")
                    .font(.system(.title3, weight: .semibold))

                Text("Connect your Claude account to monitor your usage limits in real-time.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            if authService.isAuthenticating {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Waiting for authorization...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    // Show OAuth error if present
                    if let authError = authService.lastAuthError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(authError.errorDescription ?? "Authentication failed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 4)
                    }

                    Button(action: {
                        Task {
                            authService.clearError()
                            do {
                                try await authService.startOAuthFlow()
                            } catch {
                                // Error is stored in authService.lastAuthError
                                // UI will update automatically via @Published
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "person.badge.key.fill")
                            Text("Sign in with Claude")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // Only show Claude Code option if we haven't received a restriction error
                    if KeychainService.shared.hasClaudeCodeCredentials() && !viewModel.isClaudeCodeRestricted {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Claude Code credentials detected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Use Claude Code Credentials") {
                            authService.clearError()
                            authService.checkAuthenticationStatus()
                            Task { await viewModel.refresh(userInitiated: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    } else if viewModel.isClaudeCodeRestricted {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Claude Code credentials cannot be used. Please sign in with OAuth.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }

            Spacer()

            actionsView
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Subscription Required Content

    @ViewBuilder
    private var subscriptionRequiredContent: some View {
        VStack(spacing: 20) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Color(.controlBackgroundColor))
                    .frame(width: 80, height: 80)

                Image(systemName: "creditcard.trianglebadge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
            }

            VStack(spacing: 8) {
                Text("Subscription Required")
                    .font(.system(.title3, weight: .semibold))

                Text("Monet requires a Claude Pro or Max subscription to monitor your usage limits.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)

                Text("If you recently upgraded, try refreshing your credentials.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                // Retry button for recently upgraded users
                Button(action: {
                    viewModel.clearError()
                    Task { await viewModel.refresh(userInitiated: true) }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Credentials")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Link(destination: URL(string: "https://claude.ai/upgrade")!) {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Upgrade to Pro or Max")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.controlBackgroundColor))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button("Sign Out") {
                    authService.signOut()
                    viewModel.clearError()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
            }

            Spacer()

            actionsView
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Scope Error Content

    @ViewBuilder
    private var scopeErrorContent: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(.controlBackgroundColor))
                    .frame(width: 80, height: 80)

                Image(systemName: "key.slash")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
            }

            VStack(spacing: 8) {
                Text("Credentials Need Update")
                    .font(.system(.title3, weight: .semibold))

                Text("Your Claude Code credentials are missing the required permissions (user:profile scope).")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)

                Text("Update Claude Code to the latest version, then run:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("claude logout && claude login")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
            }

            VStack(spacing: 12) {
                Button(action: {
                    viewModel.clearError()
                    Task { await viewModel.refresh(userInitiated: true) }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    viewModel.clearError()
                    Task {
                        authService.clearError()
                        try? await authService.startOAuthFlow()
                    }
                }) {
                    HStack {
                        Image(systemName: "person.badge.key.fill")
                        Text("Sign in with OAuth Instead")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.controlBackgroundColor))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button("Sign Out") {
                    authService.signOut()
                    viewModel.clearError()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
            }

            Spacer()

            actionsView
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Footer View

    @ViewBuilder
    private var footerView: some View {
        HStack {
            if let lastUpdated = viewModel.lastUpdated {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(TimeFormatter.formatRelative(lastUpdated))
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            } else {
                Text("Not updated yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                Task { await viewModel.refresh(userInitiated: true) }
            }) {
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(viewModel.isLoading)
            .help("Refresh usage data")
        }

        // Error display with recovery options
        if let error = viewModel.error {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Button(action: {
                        viewModel.clearError()
                        Task {
                            authService.clearError()
                            try? await authService.startOAuthFlow()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.badge.key.fill")
                            Text("Sign in with OAuth")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Sign Out") {
                        authService.signOut()
                        viewModel.clearError()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Actions View

    @ViewBuilder
    private var actionsView: some View {
        HStack(spacing: 12) {
            Button(action: {
                SettingsWindowController.shared.showSettings(viewModel: viewModel, authService: authService)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func loadingRow(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(.body, weight: .medium))
                Spacer()
                ProgressView()
                    .scaleEffect(0.6)
            }
            UsageProgressBar(progress: 0, color: .gray)
        }
    }

    // MARK: - Formatting Helpers

    private func formatSessionSubtitle(_ metric: UsageMetric) -> String {
        if let timeRemaining = TimeFormatter.formatCountdown(from: metric.resetsAt) {
            return "Resets in \(timeRemaining)"
        }
        return "Reset time unknown"
    }

    private func formatWeeklySubtitle(_ metric: UsageMetric) -> String {
        if let dateTime = TimeFormatter.formatDateTime(from: metric.resetsAt) {
            return "Resets \(dateTime)"
        }
        return "Reset time unknown"
    }

    private func colorForUsage(_ percentage: Double) -> Color {
        if percentage < 75 {
            return .blue
        } else if percentage < 90 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Usage Card

struct UsageCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
    }
}

// MARK: - Info Button

struct InfoButton: View {
    let tooltip: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundColor(.secondary)
            .help(tooltip)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Authenticated") {
    UsagePanel(viewModel: UsageViewModel())
        .environmentObject(AuthenticationService.shared)
}
#endif
