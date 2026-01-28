import Foundation
import AppKit

/// Update check status
enum UpdateStatus: Equatable {
    case unknown           // Haven't checked yet
    case checking          // Currently checking
    case upToDate          // Confirmed up to date
    case updateAvailable   // New version available
    case checkFailed       // Could not reach update server (private repo, network error, etc.)
}

/// Service for checking and handling app updates via GitHub Releases
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var status: UpdateStatus = .unknown
    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var releaseNotes: String?
    @Published private(set) var lastChecked: Date?

    private let currentVersion: String
    private let githubRepo = "MuGMaN/Monet"

    private init() {
        self.currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Check for updates from GitHub Releases
    func checkForUpdates() async {
        guard status != .checking else { return }

        status = .checking

        do {
            let release = try await fetchLatestRelease()

            // Parse version from tag (e.g., "v1.0.1" -> "1.0.1")
            let tagVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            latestVersion = tagVersion
            releaseNotes = release.body

            // Find DMG asset
            if let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) {
                downloadURL = URL(string: dmgAsset.browserDownloadUrl)
            }

            // Compare versions (also check if user skipped this version)
            let isNewer = isNewerVersion(tagVersion, than: currentVersion) && !isVersionSkipped(tagVersion)
            status = isNewer ? .updateAvailable : .upToDate
            lastChecked = Date()

        } catch {
            #if DEBUG
            print("Failed to check for updates: \(error)")
            #endif
            status = .checkFailed
            lastChecked = Date()
        }
    }

    /// Whether checking is in progress
    var isChecking: Bool {
        status == .checking
    }

    /// Whether an update is available
    var updateAvailable: Bool {
        status == .updateAvailable
    }

    /// Show update dialog if update is available
    func showUpdateDialogIfNeeded() {
        guard status == .updateAvailable, let latestVersion = latestVersion else { return }

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Monet \(latestVersion) is available. You are currently running \(currentVersion).\n\nWould you like to download the update?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            openDownloadPage()
        case .alertThirdButtonReturn:
            skipVersion(latestVersion)
        default:
            break
        }
    }

    /// Open the download page in browser
    func openDownloadPage() {
        if let downloadURL = downloadURL {
            NSWorkspace.shared.open(downloadURL)
        } else {
            // Fallback to releases page
            if let releasesURL = URL(string: "https://github.com/\(githubRepo)/releases/latest") {
                NSWorkspace.shared.open(releasesURL)
            }
        }
    }

    // MARK: - Private Methods

    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest") else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Monet/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw UpdateError.noReleases
        }

        guard httpResponse.statusCode == 200 else {
            throw UpdateError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newComponents = new.split(separator: ".").compactMap { Int($0) }
        let currentComponents = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(newComponents.count, currentComponents.count) {
            let newPart = i < newComponents.count ? newComponents[i] : 0
            let currentPart = i < currentComponents.count ? currentComponents[i] : 0

            if newPart > currentPart {
                return true
            } else if newPart < currentPart {
                return false
            }
        }

        return false
    }

    private func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
    }

    private func isVersionSkipped(_ version: String) -> Bool {
        return UserDefaults.standard.string(forKey: "skippedVersion") == version
    }
}

// MARK: - GitHub API Models

private struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let assets: [GitHubAsset]
    let prerelease: Bool
    let draft: Bool
}

private struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    let size: Int
    let contentType: String
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case invalidURL
    case invalidResponse
    case noReleases
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid update URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .noReleases:
            return "No releases found"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}
