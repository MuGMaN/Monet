import Foundation

// MARK: - Claude Code Keychain Structure

/// The structure of credentials stored by Claude Code in the macOS Keychain
struct ClaudeCodeCredentials: Codable {
    var claudeAiOauth: ClaudeAiOAuthToken?

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth
    }
}

/// OAuth token structure from Claude Code
struct ClaudeAiOAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Int64?  // Unix timestamp in milliseconds
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        let expirationDate = Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
        // Consider expired if less than 5 minutes remaining
        return Date().addingTimeInterval(300) > expirationDate
    }

    var needsRefresh: Bool {
        guard let expiresAt = expiresAt else { return false }
        let expirationDate = Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
        // Refresh if less than 30 minutes remaining
        return Date().addingTimeInterval(1800) > expirationDate
    }

    var expirationDate: Date? {
        guard let expiresAt = expiresAt else { return nil }
        return Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
    }

    /// Whether the subscription type indicates Pro or Max
    var hasProOrMaxSubscription: Bool {
        guard let subscriptionType = subscriptionType?.lowercased() else {
            return false
        }
        return subscriptionType.contains("pro") || subscriptionType.contains("max")
    }
}

// MARK: - Monet's Own Token Storage

/// OAuth tokens stored by Monet
struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let tokenType: String
    let obtainedAt: Date

    init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval, tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.obtainedAt = Date()
    }

    var isExpired: Bool {
        let expirationDate = obtainedAt.addingTimeInterval(expiresIn - 300) // 5-minute buffer
        return Date() > expirationDate
    }

    var needsRefresh: Bool {
        isExpired && refreshToken != nil
    }

    var expirationDate: Date {
        obtainedAt.addingTimeInterval(expiresIn)
    }
}

// MARK: - OAuth Response

/// Token response from OAuth token endpoint
struct OAuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

/// Error response from OAuth token endpoint
struct OAuthErrorResponse: Codable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

// MARK: - Authentication State

enum AuthenticationState: Equatable {
    case unknown
    case authenticated(source: AuthSource)
    case unauthenticated
    case expired
    case error(String)

    enum AuthSource: Equatable {
        case claudeCode  // Using Claude Code's credentials
        case monet       // Using Monet's own OAuth flow
    }
}
