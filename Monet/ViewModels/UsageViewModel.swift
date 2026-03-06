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

    @Published var refreshInterval: RefreshInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval")
            restartTimer()
        }
    }

    // MARK: - Private Properties

    private let apiService: UsageAPIService
    private let authService: AuthenticationService
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isRefreshing = false
    private var consecutiveRateLimits = 0

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
        self.refreshInterval = savedInterval > 0 ? RefreshInterval.closest(to: savedInterval) : .default

        // Observe auth state (removeDuplicates prevents re-firing when state is set to the same value)
        authService.$state
            .removeDuplicates()
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

    func refresh(userInitiated: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true

        // Quiet mode: when auto-retrying with a non-recoverable error, don't flash
        // the loading spinner or clear the error message. Only update UI on success.
        let quietMode = !userInitiated && error != nil && !(error?.isRecoverable ?? true)

        if !quietMode {
            isLoading = true
            error = nil
        }

        do {
            let token = try await authService.getAccessToken()
            let response = try await fetchWithRateLimitRecovery(token: token)

            sessionUsage = response.fiveHour
            weeklyUsage = response.sevenDay
            opusUsage = response.sevenDayOpus
            sonnetUsage = response.sevenDaySonnet
            lastUpdated = Date()
            error = nil
            isLoading = false
            // If we were in backoff mode, restore normal polling interval
            if consecutiveRateLimits > 0 {
                consecutiveRateLimits = 0
                restartTimer()
            }

        } catch let apiError as UsageAPIError {
            if case .rateLimited = apiError {
                handleRateLimitBackoff()
            }
            if !quietMode {
                error = apiError
                isLoading = false
            }
        } catch let authError as AuthenticationError {
            switch authError {
            case .noValidToken, .tokenExpired:
                authState = .unauthenticated
                error = nil
                isLoading = false
            case .missingScope:
                if !quietMode {
                    error = .insufficientScope(message: "OAuth token does not meet scope requirement user:profile")
                    isLoading = false
                }
            default:
                if !quietMode {
                    error = .unknown(authError)
                    isLoading = false
                }
            }
        } catch {
            if !quietMode {
                self.error = .unknown(error)
                isLoading = false
            }
        }

        isRefreshing = false
    }

    /// Attempt the fetch; if rate limited, refresh the token and retry once.
    /// The usage API rate limit is per-access-token (~5 requests), so a fresh
    /// token gets a fresh rate limit window.
    private func fetchWithRateLimitRecovery(token: String) async throws -> UsageResponse {
        do {
            return try await apiService.fetchUsage(token: token)
        } catch let apiError as UsageAPIError {
            guard case .rateLimited = apiError else { throw apiError }

            // Token's rate limit exhausted — refresh to get a new window
            #if DEBUG
            print("🔄 Rate limited on usage API, refreshing token...")
            #endif

            do {
                let newToken = try await authService.forceTokenRefresh()
                return try await apiService.fetchUsage(token: newToken)
            } catch {
                // If refresh failed or still rate limited, surface the original 429
                throw apiError
            }
        }
    }

    /// Back off polling when we keep hitting rate limits.
    private func handleRateLimitBackoff() {
        consecutiveRateLimits += 1
        // Exponential backoff: 60s, 120s, 240s, capped at 1hr
        let backoff = min(
            Constants.Timing.maximumRefreshInterval,
            refreshInterval.rawValue * pow(2.0, Double(consecutiveRateLimits - 1))
        )
        #if DEBUG
        print("⏳ Rate limit backoff: \(backoff)s (consecutive: \(consecutiveRateLimits))")
        #endif
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: backoff, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }


    func clearError() {
        error = nil
    }

    // MARK: - Private Methods

    private func restartTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval.rawValue, repeats: true) { [weak self] _ in
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

    /// Whether the user has weekly limits (Max users have them, Pro users don't)
    var hasWeeklyLimits: Bool {
        weeklyUsage != nil || opusUsage != nil || sonnetUsage != nil
    }

    /// Whether Claude Code credentials have been restricted by Anthropic
    var isClaudeCodeRestricted: Bool {
        error?.isClaudeCodeRestricted ?? false
    }
}
