import Foundation
import AppKit
import CryptoKit
import Network

// MARK: - Authentication Service

@MainActor
final class AuthenticationService: NSObject, ObservableObject {
    static let shared = AuthenticationService()

    @Published private(set) var state: AuthenticationState = .unknown
    @Published private(set) var isAuthenticating = false

    private let keychain = KeychainService.shared
    private var codeVerifier: String?
    private var httpServer: LocalHTTPServer?

    override init() {
        super.init()
        checkAuthenticationStatus()
    }

    // MARK: - Public Methods

    /// Get a valid access token
    func getAccessToken() async throws -> String {
        // Try Claude Code's tokens first (they work with the usage API!)
        if let token = try? await getClaudeCodeToken() {
            state = .authenticated(source: .claudeCode)
            return token
        }

        // Try Monet's own tokens as fallback
        if let token = try? await getMonetToken() {
            state = .authenticated(source: .monet)
            return token
        }

        state = .unauthenticated
        throw AuthenticationError.noValidToken
    }

    /// Get token from Claude Code credentials
    private func getClaudeCodeToken() async throws -> String {
        let credentials = try keychain.readClaudeCodeCredentials()

        // Check if token needs refresh
        if credentials.isExpired || credentials.needsRefresh {
            if let refreshToken = credentials.refreshToken {
                let newTokens = try await refreshClaudeCodeToken(refreshToken: refreshToken)
                // Update stored credentials
                try keychain.updateClaudeCodeTokens(
                    accessToken: newTokens.accessToken,
                    refreshToken: newTokens.refreshToken ?? refreshToken,
                    expiresAt: Date().addingTimeInterval(newTokens.expiresIn)
                )
                return newTokens.accessToken
            }
            throw AuthenticationError.tokenExpired
        }

        return credentials.accessToken
    }

    /// Refresh Claude Code token
    private func refreshClaudeCodeToken(refreshToken: String) async throws -> OAuthTokens {
        guard let url = URL(string: "https://api.anthropic.com/v1/oauth/token") else {
            throw AuthenticationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Constants.OAuth.clientID
        ]

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AuthenticationError.tokenRefreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

        return OAuthTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: TimeInterval(tokenResponse.expiresIn),
            tokenType: tokenResponse.tokenType ?? "Bearer"
        )
    }

    /// Check if we have valid credentials
    func checkAuthenticationStatus() {
        // Check Claude Code tokens first
        if let credentials = try? keychain.readClaudeCodeCredentials(), !credentials.isExpired {
            state = .authenticated(source: .claudeCode)
            return
        }

        // Check Monet's own tokens
        if let tokens = try? keychain.readMonetTokens(for: "default"), !tokens.isExpired {
            state = .authenticated(source: .monet)
            return
        }

        state = .unauthenticated
    }

    /// Start the OAuth authentication flow
    func startOAuthFlow() async throws {
        isAuthenticating = true

        do {
            // Generate PKCE parameters
            let codeVerifier = generateCodeVerifier()
            self.codeVerifier = codeVerifier
            let codeChallenge = generateCodeChallenge(from: codeVerifier)
            let stateParam = generateRandomState()

            // Build authorization URL
            guard var components = URLComponents(string: Constants.API.authorizationEndpoint) else {
                throw AuthenticationError.invalidURL
            }

            components.queryItems = [
                URLQueryItem(name: "client_id", value: Constants.OAuth.clientID),
                URLQueryItem(name: "redirect_uri", value: Constants.OAuth.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Constants.OAuth.scopes),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: stateParam)
            ]

            guard let authURL = components.url else {
                throw AuthenticationError.invalidURL
            }

            // Start local HTTP server to receive callback
            let server = LocalHTTPServer(port: Constants.OAuth.callbackPort)
            self.httpServer = server
            try await server.start()

            // Open browser for authorization
            NSWorkspace.shared.open(authURL)

            // Wait for callback
            let receivedURL = try await server.waitForCallback()

            // Stop server
            await server.stop()
            self.httpServer = nil

            // Extract authorization code from callback
            guard let urlComponents = URLComponents(url: receivedURL, resolvingAgainstBaseURL: false),
                  let queryItems = urlComponents.queryItems else {
                throw AuthenticationError.invalidCallback
            }

            // Verify state
            let receivedState = queryItems.first(where: { $0.name == "state" })?.value
            guard receivedState == stateParam else {
                throw AuthenticationError.stateMismatch
            }

            // Get authorization code
            guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
                if let error = queryItems.first(where: { $0.name == "error" })?.value {
                    throw AuthenticationError.serverError(error)
                }
                throw AuthenticationError.noAuthorizationCode
            }

            // Exchange code for tokens
            let tokens = try await exchangeCodeForTokens(code: code)

            // Save tokens
            try keychain.saveMonetTokens(tokens, for: "default")

            self.state = .authenticated(source: .monet)
            isAuthenticating = false

        } catch {
            isAuthenticating = false
            await httpServer?.stop()
            httpServer = nil
            throw error
        }
    }

    /// Sign out
    func signOut() {
        try? keychain.deleteMonetTokens(for: "default")
        state = .unauthenticated
    }

    // MARK: - Private Methods

    private func getMonetToken() async throws -> String {
        let tokens = try keychain.readMonetTokens(for: "default")

        // Check if refresh needed
        if tokens.needsRefresh, let refreshToken = tokens.refreshToken {
            let newTokens = try await refreshAccessToken(refreshToken: refreshToken)
            try keychain.saveMonetTokens(newTokens, for: "default")
            return newTokens.accessToken
        }

        if tokens.isExpired {
            throw AuthenticationError.tokenExpired
        }

        return tokens.accessToken
    }

    private func exchangeCodeForTokens(code: String) async throws -> OAuthTokens {
        guard let url = URL(string: Constants.API.tokenEndpoint),
              let codeVerifier = codeVerifier else {
            throw AuthenticationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "client_id=\(Constants.OAuth.clientID)",
            "code=\(code)",
            "code_verifier=\(codeVerifier)",
            "redirect_uri=\(Constants.OAuth.redirectURI)"
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthenticationError.tokenExchangeFailed
        }

        if httpResponse.statusCode != 200 {
            throw AuthenticationError.tokenExchangeFailed
        }

        let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

        return OAuthTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: TimeInterval(tokenResponse.expiresIn),
            tokenType: tokenResponse.tokenType ?? "Bearer"
        )
    }

    private func refreshAccessToken(refreshToken: String) async throws -> OAuthTokens {
        guard let url = URL(string: Constants.API.tokenEndpoint) else {
            throw AuthenticationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "client_id=\(Constants.OAuth.clientID)",
            "refresh_token=\(refreshToken)"
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AuthenticationError.tokenRefreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

        return OAuthTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expiresIn: TimeInterval(tokenResponse.expiresIn),
            tokenType: tokenResponse.tokenType ?? "Bearer"
        )
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else {
            fatalError("Could not encode verifier")
        }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }

    private func generateRandomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

// MARK: - Local HTTP Server for OAuth Callback

actor LocalHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?

    init(port: UInt16) {
        self.port = port
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true

                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        Task { await self.resumeStart(with: nil) }
                    case .failed:
                        Task { await self.resumeStart(with: AuthenticationError.failedToStart) }
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self else { return }
                    Task { await self.handleConnection(connection) }
                }

                self.startContinuation = continuation
                listener.start(queue: .global())

            } catch {
                continuation.resume(throwing: AuthenticationError.failedToStart)
            }
        }
    }

    private func resumeStart(with error: Error?) {
        if let error = error {
            startContinuation?.resume(throwing: error)
        } else {
            startContinuation?.resume()
        }
        startContinuation = nil
    }

    func waitForCallback() async throws -> URL {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.callbackContinuation = continuation
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            if let data = data, let request = String(data: data, encoding: .utf8) {
                // Parse HTTP request to get the URL
                let lines = request.components(separatedBy: "\r\n")
                if let firstLine = lines.first {
                    let parts = firstLine.components(separatedBy: " ")
                    if parts.count >= 2 {
                        let path = parts[1]
                        if let url = URL(string: "http://localhost:\(self.port)\(path)") {
                            // Send success response
                            let response = """
                            HTTP/1.1 200 OK\r
                            Content-Type: text/html\r
                            Connection: close\r
                            \r
                            <!DOCTYPE html>
                            <html>
                            <head><title>Monet - Authorization Complete</title></head>
                            <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #1a1a1a; color: white;">
                                <div style="text-align: center;">
                                    <h1>Authorization Successful!</h1>
                                    <p>You can close this window and return to Monet.</p>
                                </div>
                            </body>
                            </html>
                            """

                            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                                connection.cancel()
                            })

                            Task { await self.resumeWithURL(url) }
                            return
                        }
                    }
                }
            }

            // Error response
            let errorResponse = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nInvalid request"
            connection.send(content: errorResponse.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func resumeWithURL(_ url: URL) {
        callbackContinuation?.resume(returning: url)
        callbackContinuation = nil
    }

    private func resumeWithError(_ error: Error) {
        callbackContinuation?.resume(throwing: error)
        callbackContinuation = nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Base64 URL Encoding

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

// MARK: - Authentication Errors

enum AuthenticationError: LocalizedError {
    case noValidToken
    case tokenExpired
    case invalidURL
    case userCancelled
    case noCallbackURL
    case failedToStart
    case invalidCallback
    case stateMismatch
    case noAuthorizationCode
    case serverError(String)
    case tokenExchangeFailed
    case tokenRefreshFailed
    case oauthError(Error)

    var errorDescription: String? {
        switch self {
        case .noValidToken:
            return "No valid authentication token found"
        case .tokenExpired:
            return "Authentication token has expired"
        case .invalidURL:
            return "Invalid authentication URL"
        case .userCancelled:
            return "Authentication was cancelled"
        case .noCallbackURL:
            return "No callback URL received"
        case .failedToStart:
            return "Failed to start authentication session"
        case .invalidCallback:
            return "Invalid callback received"
        case .stateMismatch:
            return "Security state mismatch"
        case .noAuthorizationCode:
            return "No authorization code received"
        case .serverError(let message):
            return "Server error: \(message)"
        case .tokenExchangeFailed:
            return "Failed to exchange code for tokens"
        case .tokenRefreshFailed:
            return "Failed to refresh access token"
        case .oauthError(let error):
            return "OAuth error: \(error.localizedDescription)"
        }
    }
}
