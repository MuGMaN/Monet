import Foundation

// MARK: - API Response

/// Response from the usage API endpoint
struct UsageResponse: Codable {
    let fiveHour: UsageMetric?
    let sevenDay: UsageMetric?
    let sevenDayOpus: UsageMetric?
    let sevenDaySonnet: UsageMetric?
    let sevenDayOauthApps: UsageMetric?
    let iguanaNecktie: String?  // Unknown field in API response

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case iguanaNecktie = "iguana_necktie"
    }
}

/// Individual usage metric
struct UsageMetric: Codable, Equatable {
    /// Usage percentage (0-100)
    let utilization: Double

    /// ISO 8601 timestamp when the usage resets
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// Parse the reset time as a Date
    var resetDate: Date? {
        guard let resetsAt = resetsAt else { return nil }
        return ISO8601DateFormatter().date(from: resetsAt)
    }

    /// Time remaining until reset
    var timeUntilReset: TimeInterval? {
        guard let resetDate = resetDate else { return nil }
        let interval = resetDate.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }

    /// Whether usage is in warning range (75-90%)
    var isWarning: Bool {
        utilization >= 75 && utilization < 90
    }

    /// Whether usage is critical (>90%)
    var isCritical: Bool {
        utilization >= 90
    }
}

// MARK: - Display Models

/// Formatted usage data for display
struct UsageDisplayData {
    let sessionUsage: UsageMetric?
    let weeklyUsage: UsageMetric?
    let opusUsage: UsageMetric?
    let sonnetUsage: UsageMetric?
    let lastUpdated: Date

    init(from response: UsageResponse) {
        self.sessionUsage = response.fiveHour
        self.weeklyUsage = response.sevenDay
        self.opusUsage = response.sevenDayOpus
        self.sonnetUsage = response.sevenDaySonnet
        self.lastUpdated = Date()
    }

    /// Check if any usage is at critical levels
    var hasCriticalUsage: Bool {
        sessionUsage?.isCritical ?? false ||
        weeklyUsage?.isCritical ?? false ||
        opusUsage?.isCritical ?? false ||
        sonnetUsage?.isCritical ?? false
    }

    /// Check if any usage is at warning levels
    var hasWarningUsage: Bool {
        sessionUsage?.isWarning ?? false ||
        weeklyUsage?.isWarning ?? false ||
        opusUsage?.isWarning ?? false ||
        sonnetUsage?.isWarning ?? false
    }
}

// MARK: - Error Types

enum UsageAPIError: LocalizedError {
    case invalidToken
    case noSubscription
    case claudeCodeCredentialsRestricted
    case insufficientScope(message: String?)
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int, message: String?)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Authentication token is invalid or expired. Try signing out and back in."
        case .noSubscription:
            return "Claude Pro or Max subscription required to view usage data."
        case .claudeCodeCredentialsRestricted:
            return "Claude Code credentials cannot be used with third-party apps. Please sign in with OAuth instead."
        case .insufficientScope(let message):
            if let msg = message, msg.contains("user:profile") {
                return "Your credentials are missing the required scope. Update Claude Code, then run 'claude logout' and 'claude login' in Terminal."
            }
            if let msg = message, !msg.isEmpty {
                return "Insufficient permissions: \(msg)"
            }
            return "Insufficient permissions. Try signing out and signing in again."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .rateLimited(let retryAfter):
            if let retry = retryAfter {
                return "Rate limited. Try again in \(Int(retry)) seconds"
            }
            return "Rate limited. Please try again later"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message ?? "Unknown error")"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .networkError, .rateLimited, .serverError:
            return true
        case .invalidToken, .noSubscription, .claudeCodeCredentialsRestricted, .insufficientScope, .invalidResponse, .decodingError, .unknown:
            return false
        }
    }

    /// Whether this error means Claude Code credentials can't be used
    var isClaudeCodeRestricted: Bool {
        if case .claudeCodeCredentialsRestricted = self {
            return true
        }
        return false
    }

    /// Whether this error indicates the user needs a Pro/Max subscription
    var requiresSubscription: Bool {
        if case .noSubscription = self {
            return true
        }
        return false
    }

    /// Whether this error indicates a missing OAuth scope
    var isScopeError: Bool {
        if case .insufficientScope = self {
            return true
        }
        return false
    }
}
