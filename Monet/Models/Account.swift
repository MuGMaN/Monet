import Foundation

/// Account model - designed for future multi-account support
struct Account: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isActive: Bool
    var createdAt: Date
    var lastUsed: Date?

    /// Source of authentication for this account
    var authSource: AuthSourceType

    enum AuthSourceType: String, Codable, Equatable {
        case claudeCode  // Using credentials from Claude Code
        case oauth       // Using Monet's own OAuth
    }

    init(
        id: UUID = UUID(),
        name: String = "Default",
        isActive: Bool = true,
        authSource: AuthSourceType = .claudeCode
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.authSource = authSource
        self.createdAt = Date()
        self.lastUsed = nil
    }

    /// Keychain key for storing this account's credentials
    var keychainKey: String {
        "account-\(id.uuidString)"
    }
}

// MARK: - Account Manager

/// Manages accounts - currently single account, designed for future multi-account support
@MainActor
class AccountManager: ObservableObject {
    @Published private(set) var currentAccount: Account?

    // Future: @Published var accounts: [Account] = []

    private let defaults = UserDefaults.standard
    private let accountKey = "com.monet.currentAccount"

    init() {
        loadCurrentAccount()
    }

    func getActiveAccount() -> Account? {
        currentAccount
    }

    func setCurrentAccount(_ account: Account) {
        currentAccount = account
        saveCurrentAccount()
    }

    func createDefaultAccount(authSource: Account.AuthSourceType) -> Account {
        let account = Account(authSource: authSource)
        currentAccount = account
        saveCurrentAccount()
        return account
    }

    func clearAccount() {
        currentAccount = nil
        defaults.removeObject(forKey: accountKey)
    }

    // MARK: - Persistence

    private func loadCurrentAccount() {
        guard let data = defaults.data(forKey: accountKey),
              let account = try? JSONDecoder().decode(Account.self, from: data) else {
            return
        }
        currentAccount = account
    }

    private func saveCurrentAccount() {
        guard let account = currentAccount,
              let data = try? JSONEncoder().encode(account) else {
            return
        }
        defaults.set(data, forKey: accountKey)
    }

    // MARK: - Future Multi-Account Methods

    // func addAccount(_ account: Account) { ... }
    // func removeAccount(_ id: UUID) { ... }
    // func switchAccount(_ id: UUID) { ... }
}
