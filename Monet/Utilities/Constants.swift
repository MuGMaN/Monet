import Foundation

enum Constants {
    // MARK: - API Endpoints
    enum API {
        static let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"
        static let authorizationEndpoint = "https://claude.ai/oauth/authorize"
        static let tokenEndpoint = "https://platform.claude.com/v1/oauth/token"
    }

    // MARK: - OAuth Configuration
    enum OAuth {
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        // Must match Claude Code's registered redirect URI format
        static let redirectURI = "http://localhost:54545/callback"
        static let callbackScheme = "http"
        static let callbackPort: UInt16 = 54545
        static let scopes = "user:profile"
    }

    // MARK: - Keychain
    enum Keychain {
        static let claudeCodeService = "Claude Code-credentials"
        static let monetService = "com.monet.usage-monitor"
        static let accountCredentials = "credentials"
        static let claudeCodeCache = "claude-code-cache"
    }

    // MARK: - API Headers
    enum Headers {
        static let anthropicBeta = "oauth-2025-04-20"
        static let userAgent = "monet/1.0.0"
    }

    // MARK: - Timing
    enum Timing {
        static let defaultRefreshInterval: TimeInterval = 60  // 60 seconds
        static let maximumRefreshInterval: TimeInterval = 3600 // 1 hour (backoff cap)
    }

    // MARK: - Notifications
    enum Notifications {
        static let defaultThresholds: [Double] = [75, 90, 95]
    }

    // MARK: - App Info
    enum App {
        static let bundleID = "com.monet.usage-monitor"
        static let name = "Monet"
    }
}

// MARK: - Refresh Interval Presets

enum RefreshInterval: TimeInterval, CaseIterable, Codable {
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1800
    case oneHour = 3600

    var label: String {
        switch self {
        case .tenSeconds: return "10 seconds"
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .threeMinutes: return "3 minutes"
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        }
    }

    static let `default`: RefreshInterval = .oneMinute

    /// Find the closest preset for a saved TimeInterval value
    static func closest(to interval: TimeInterval) -> RefreshInterval {
        allCases.min(by: { abs($0.rawValue - interval) < abs($1.rawValue - interval) }) ?? .default
    }
}
