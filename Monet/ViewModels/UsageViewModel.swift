import Foundation
import Combine

// MARK: - Menu Bar Display Mode

enum MenuBarDisplayMode: String, CaseIterable, Codable {
    case minimal = "Minimal"      // ◐ 32%
    case normal = "Normal"        // ◐ 32% 2:11
    case verbose = "Verbose"      // ◐ 32% 2:11:45

    var description: String {
        switch self {
        case .minimal: return "Gauge + Percentage"
        case .normal: return "Gauge + Percentage + Time"
        case .verbose: return "Gauge + Percentage + Time (with seconds)"
        }
    }
}

// MARK: - Usage View Model

@MainActor
final class UsageViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var sessionUsage: UsageMetric?
    @Published private(set) var weeklyUsage: UsageMetric?
    @Published private(set) var opusUsage: UsageMetric?
    @Published private(set) var sonnetUsage: UsageMetric?
    @Published private(set) var isLoading = false
    @Published private(set) var error: UsageAPIError?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var authState: AuthenticationState = .unknown

    @Published var displayMode: MenuBarDisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "menuBarDisplayMode")
        }
    }

    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartTimer()
        }
    }

    // MARK: - Private Properties

    private let apiService: UsageAPIService
    private let authService: AuthenticationService
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    @MainActor
    init(
        apiService: UsageAPIService = UsageAPIService.shared,
        authService: AuthenticationService = AuthenticationService.shared
    ) {
        self.apiService = apiService
        self.authService = authService

        // Load saved preferences
        if let modeString = UserDefaults.standard.string(forKey: "menuBarDisplayMode"),
           let mode = MenuBarDisplayMode(rawValue: modeString) {
            self.displayMode = mode
        } else {
            self.displayMode = .normal
        }

        let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        self.refreshInterval = savedInterval > 0 ? savedInterval : Constants.Timing.defaultRefreshInterval

        // Observe auth state
        authService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.authState = state
                if case .authenticated = state {
                    Task { await self?.refresh() }
                }
            }
            .store(in: &cancellables)

        // Start monitoring
        startMonitoring()
    }

    deinit {
        // Timer invalidation is thread-safe
        refreshTimer?.invalidate()
    }

    // MARK: - Public Methods

    func startMonitoring() {
        Task {
            await refresh()
        }
        restartTimer()
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            let token = try await authService.getAccessToken()
            let response = try await apiService.fetchUsage(token: token)

            sessionUsage = response.fiveHour
            weeklyUsage = response.sevenDay
            opusUsage = response.sevenDayOpus
            sonnetUsage = response.sevenDaySonnet
            lastUpdated = Date()
            error = nil

        } catch let apiError as UsageAPIError {
            error = apiError
            if case .invalidToken = apiError {
                authService.checkAuthenticationStatus()
            }
        } catch let authError as AuthenticationError {
            switch authError {
            case .noValidToken, .tokenExpired:
                authState = .unauthenticated
            case .missingScope:
                // Claude Code credentials lack required scope - show as scope error
                error = .insufficientScope(message: "OAuth token does not meet scope requirement user:profile")
            default:
                error = .unknown(authError)
            }
        } catch {
            self.error = .unknown(error)
        }

        isLoading = false
    }

    func clearError() {
        error = nil
    }

    // MARK: - Private Methods

    private func restartTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }
}

// MARK: - Computed Properties

extension UsageViewModel {
    /// Session usage percentage (0-100)
    var sessionPercentage: Double {
        sessionUsage?.utilization ?? 0
    }

    /// Whether any usage is at critical level
    var hasCriticalUsage: Bool {
        sessionUsage?.isCritical ?? false ||
        weeklyUsage?.isCritical ?? false ||
        opusUsage?.isCritical ?? false ||
        sonnetUsage?.isCritical ?? false
    }

    /// Whether any usage is at warning level
    var hasWarningUsage: Bool {
        sessionUsage?.isWarning ?? false ||
        weeklyUsage?.isWarning ?? false ||
        opusUsage?.isWarning ?? false ||
        sonnetUsage?.isWarning ?? false
    }

    /// Formatted time remaining for session
    var sessionTimeRemaining: String? {
        guard let resetsAt = sessionUsage?.resetsAt else { return nil }
        return TimeFormatter.formatCompactTime(from: resetsAt, verbose: displayMode == .verbose)
    }

    /// Whether authenticated
    var isAuthenticated: Bool {
        if case .authenticated = authState {
            return true
        }
        return false
    }

    /// Whether Claude Code credentials have been restricted by Anthropic
    var isClaudeCodeRestricted: Bool {
        error?.isClaudeCodeRestricted ?? false
    }
}
