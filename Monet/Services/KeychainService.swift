import Foundation
import Security

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case itemNotFound
    case duplicateItem
    case invalidItemFormat
    case unexpectedStatus(OSStatus)
    case encodingError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Keychain item not found"
        case .duplicateItem:
            return "Keychain item already exists"
        case .invalidItemFormat:
            return "Invalid keychain item format"
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error: \(status)"
        case .encodingError:
            return "Failed to encode data for keychain"
        case .decodingError:
            return "Failed to decode keychain data"
        }
    }
}

// MARK: - Keychain Service

final class KeychainService {
    static let shared = KeychainService()

    private init() {}

    // MARK: - Read Operations

    /// Read raw data from keychain
    func read(service: String, account: String? = nil) throws -> Data {
        var query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue
        ]

        if let account = account {
            query[kSecAttrAccount as String] = account as AnyObject
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidItemFormat
        }

        return data
    }

    /// Read and decode JSON from keychain
    func readJSON<T: Decodable>(service: String, account: String? = nil, as type: T.Type) throws -> T {
        let data = try read(service: service, account: account)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw KeychainError.decodingError
        }
    }

    /// Read string from keychain
    func readString(service: String, account: String? = nil) throws -> String {
        let data = try read(service: service, account: account)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidItemFormat
        }
        return string
    }

    // MARK: - Write Operations

    /// Save raw data to keychain
    func save(data: Data, service: String, account: String) throws {
        // First try to delete existing item
        try? delete(service: service, account: account)

        let query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: account as AnyObject,
            kSecValueData as String: data as AnyObject,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Save JSON-encodable object to keychain
    func saveJSON<T: Encodable>(_ object: T, service: String, account: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(object)
        } catch {
            throw KeychainError.encodingError
        }
        try save(data: data, service: service, account: account)
    }

    /// Save string to keychain
    func saveString(_ string: String, service: String, account: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        try save(data: data, service: service, account: account)
    }

    // MARK: - Delete Operations

    /// Delete item from keychain
    func delete(service: String, account: String? = nil) throws {
        var query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject
        ]

        if let account = account {
            query[kSecAttrAccount as String] = account as AnyObject
        }

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Claude Code Credentials

    /// Read Claude Code OAuth credentials from keychain
    func readClaudeCodeCredentials() throws -> ClaudeAiOAuthToken {
        let data = try read(service: Constants.Keychain.claudeCodeService)

        // Claude Code stores credentials as JSON string
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidItemFormat
        }

        // Parse the JSON
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw KeychainError.invalidItemFormat
        }

        let credentials = try JSONDecoder().decode(ClaudeCodeCredentials.self, from: jsonData)

        guard let oauthToken = credentials.claudeAiOauth else {
            throw KeychainError.itemNotFound
        }

        return oauthToken
    }

    /// Check if Claude Code credentials exist
    func hasClaudeCodeCredentials() -> Bool {
        do {
            _ = try readClaudeCodeCredentials()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Monet's Own Credentials

    /// Save Monet's OAuth tokens
    func saveMonetTokens(_ tokens: OAuthTokens, for accountId: String) throws {
        try saveJSON(tokens, service: Constants.Keychain.monetService, account: accountId)
    }

    /// Read Monet's OAuth tokens
    func readMonetTokens(for accountId: String) throws -> OAuthTokens {
        try readJSON(
            service: Constants.Keychain.monetService,
            account: accountId,
            as: OAuthTokens.self
        )
    }

    /// Delete Monet's tokens
    func deleteMonetTokens(for accountId: String) throws {
        try delete(service: Constants.Keychain.monetService, account: accountId)
    }
}
