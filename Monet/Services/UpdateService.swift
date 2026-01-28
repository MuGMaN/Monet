import Foundation
import AppKit

/// Update check status
enum UpdateStatus: Equatable {
    case unknown           // Haven't checked yet
    case checking          // Currently checking
    case upToDate          // Confirmed up to date
    case updateAvailable   // New version available
    case checkFailed       // Could not reach update server (private repo, network error, etc.)
    case downloading       // Downloading update
    case installing        // Installing update
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
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var installError: String?

    private let currentVersion: String
    private let githubRepo = "MuGMaN/Monet"
    private var downloadTask: URLSessionDownloadTask?

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
        alert.informativeText = "Monet \(latestVersion) is available. You are currently running \(currentVersion).\n\nWould you like to install the update now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            Task {
                await installUpdate()
            }
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

    /// Download and install the update automatically
    func installUpdate() async {
        guard let downloadURL = downloadURL else {
            installError = "No download URL available"
            return
        }

        status = .downloading
        downloadProgress = 0
        installError = nil

        do {
            // 1. Download DMG to temp location
            let dmgPath = try await downloadDMG(from: downloadURL)

            status = .installing

            // 2. Mount the DMG
            let mountPoint = try await mountDMG(at: dmgPath)

            // 3. Find the .app in the mounted volume
            let appSourcePath = try findAppInVolume(mountPoint)

            // 4. Get current app location
            let currentAppPath = Bundle.main.bundlePath

            // 5. Create and execute update script
            try executeUpdateScript(
                sourceApp: appSourcePath,
                destinationApp: currentAppPath,
                mountPoint: mountPoint,
                dmgPath: dmgPath
            )

            // The script will handle quitting and relaunching
            // Give it a moment to start, then quit
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            NSApp.terminate(nil)

        } catch {
            status = .updateAvailable
            installError = error.localizedDescription
            showInstallErrorAlert(error)
        }
    }

    // MARK: - Private Methods

    private func downloadDMG(from url: URL) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let dmgPath = tempDir.appendingPathComponent("Monet-update.dmg")

        // Remove any existing file
        try? FileManager.default.removeItem(at: dmgPath)

        // Create a download delegate to track progress
        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        // Move to our desired location
        try FileManager.default.moveItem(at: tempURL, to: dmgPath)

        return dmgPath.path
    }

    private func mountDMG(at path: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path, "-nobrowse", "-quiet", "-mountrandom", "/tmp"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.mountFailed
        }

        // Find the mount point
        let listProcess = Process()
        listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        listProcess.arguments = ["info", "-plist"]

        let listPipe = Pipe()
        listProcess.standardOutput = listPipe

        try listProcess.run()
        listProcess.waitUntilExit()

        let data = listPipe.fileHandleForReading.readDataToEndOfFile()

        // Parse plist to find mount point for our DMG
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let images = plist["images"] as? [[String: Any]] {
            for image in images {
                if let imagePath = image["image-path"] as? String,
                   imagePath == path,
                   let entities = image["system-entities"] as? [[String: Any]] {
                    for entity in entities {
                        if let mountPoint = entity["mount-point"] as? String {
                            return mountPoint
                        }
                    }
                }
            }
        }

        throw UpdateError.mountFailed
    }

    private func findAppInVolume(_ mountPoint: String) throws -> String {
        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.appNotFound
        }
        return (mountPoint as NSString).appendingPathComponent(appName)
    }

    private func executeUpdateScript(sourceApp: String, destinationApp: String, mountPoint: String, dmgPath: String) throws {
        // Create a shell script that will:
        // 1. Wait for the current app to quit
        // 2. Remove the old app
        // 3. Copy the new app
        // 4. Unmount the DMG
        // 5. Clean up the DMG file
        // 6. Launch the new app
        // 7. Remove itself

        let script = """
        #!/bin/bash

        # Wait for the app to quit (check by PID)
        APP_PID=\(ProcessInfo.processInfo.processIdentifier)
        while kill -0 $APP_PID 2>/dev/null; do
            sleep 0.5
        done

        # Small delay to ensure everything is released
        sleep 1

        # Remove old app
        rm -rf "\(destinationApp)"

        # Copy new app
        cp -R "\(sourceApp)" "\(destinationApp)"

        # Fix permissions
        chmod -R 755 "\(destinationApp)"
        xattr -cr "\(destinationApp)"

        # Unmount DMG
        hdiutil detach "\(mountPoint)" -quiet

        # Remove DMG
        rm -f "\(dmgPath)"

        # Launch new app
        open "\(destinationApp)"

        # Remove this script
        rm -f "$0"
        """

        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("monet_update.sh")

        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        // Make executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Execute script in background
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath.path]
        process.standardOutput = nil
        process.standardError = nil

        try process.run()
    }

    private func showInstallErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Update Failed"
        alert.informativeText = "Failed to install the update: \(error.localizedDescription)\n\nWould you like to download it manually?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Download Manually")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            openDownloadPage()
        }
    }

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

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void

    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async call
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case invalidURL
    case invalidResponse
    case noReleases
    case httpError(Int)
    case downloadFailed
    case mountFailed
    case appNotFound
    case installFailed(String)

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
        case .downloadFailed:
            return "Failed to download update"
        case .mountFailed:
            return "Failed to mount disk image"
        case .appNotFound:
            return "App not found in disk image"
        case .installFailed(let reason):
            return "Installation failed: \(reason)"
        }
    }
}
