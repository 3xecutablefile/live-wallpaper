//
//  LockScreenManager.swift
//  LiveWallpaper
//
//  Port of the lock-screen aerial staging mechanism used by Backdrop (Cindori):
//  the system plays lock-screen "aerials" from a known video store; by backing up
//  and overwriting those files with the user's video (then restarting WallpaperAgent)
//  the video appears on the lock screen natively — no screensaver plugin needed.
//
//  On macOS 26 (Tahoe) the aerial store lives in the user's Library, so no root is
//  required. On macOS 14–15 it lives under /Library and needs an admin prompt.
//

import Foundation
import AppKit

class LockScreenManager: ObservableObject {

    static let shared = LockScreenManager()

    // MARK: - Published UI state

    /// Whether the lock screen aerials have been replaced with the user's video.
    @Published var isReplaced: Bool = false
    /// True while a replace/restore operation is in flight.
    @Published var isBusy: Bool = false
    /// Last error message, shown in the UI.
    @Published var lastError: String?

    // MARK: - Paths

    private var videosPath: String {
        // macOS 26 (Tahoe) uses a new location in the user's Library.
        let newPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
            .path

        if FileManager.default.fileExists(atPath: newPath) {
            return newPath
        }

        // Fallback: macOS 14–15 (Sonoma/Sequoia).
        return "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS"
    }

    private let wallpaperIndexPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }()

    // MARK: - Persistence

    private enum Key: String {
        case replacedVideoURL = "LockScreenManager.replacedVideoURL"
    }

    private var replacedVideoURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Key.replacedVideoURL.rawValue) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            if let url = newValue {
                UserDefaults.standard.set(url.path, forKey: Key.replacedVideoURL.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.replacedVideoURL.rawValue)
            }
        }
    }

    // MARK: - Init

    private init() {
        isReplaced = canRestore
        observeWake()
    }

    /// macOS can restore the original aerials after wake/unlock, so re-apply the
    /// swap when the machine wakes or the screen is unlocked (mirrors Backdrop's
    /// validateAndRepairUnlocked behavior).
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleWake),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func handleWake() {
        guard let videoURL = replacedVideoURL, isReplaced else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.silentReplace(with: videoURL)
        }
    }

    private func silentReplace(with videoURL: URL) {
        let info = currentWallpaperInfo()
        guard !info.isEmpty, info.allVideosExist else { return }

        do {
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("livewallpaper_lock_replace.mov").path
            try? FileManager.default.removeItem(atPath: tempPath)
            try FileManager.default.copyItem(at: videoURL, to: URL(fileURLWithPath: tempPath))

            var commands: [String] = []
            for video in info.videos {
                commands.append("cp '\(tempPath)' '\(video.videoPath)'")
            }

            try runShell(commands.joined(separator: " && "))
            try? FileManager.default.removeItem(atPath: tempPath)

            restartWallpaperAgent()
        } catch {
            print("Lock screen silent re-apply failed: \(error)")
        }
    }

    // MARK: - Permission

    var hasWritePermission: Bool {
        guard FileManager.default.isWritableFile(atPath: videosPath) else {
            return false
        }
        let info = currentWallpaperInfo()
        return info.videos.allSatisfy { video in
            !video.videoExists || FileManager.default.isWritableFile(atPath: video.videoPath)
        }
    }

    /// One-time setup: take ownership of the aerial store (needed on macOS 14–15).
    func requestWritePermission(completion: @escaping (Bool) -> Void) {
        let username = NSUserName()
        let script = "do shell script \"chown -R \(username) '\(videosPath)' && chmod -R u+rw '\(videosPath)'\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&errorInfo)
            }
            DispatchQueue.main.async {
                completion(errorInfo == nil)
            }
        }
    }

    // MARK: - Wallpaper info

    private struct VideoInfo {
        let assetID: String
        let videoPath: String
        let backupPath: String

        var videoExists: Bool {
            FileManager.default.fileExists(atPath: videoPath)
        }

        var backupExists: Bool {
            FileManager.default.fileExists(atPath: backupPath)
        }
    }

    private struct WallpaperInfo {
        let videos: [VideoInfo]

        var isEmpty: Bool {
            videos.isEmpty
        }

        var allVideosExist: Bool {
            videos.allSatisfy { $0.videoExists }
        }
    }

    private func currentWallpaperInfo() -> WallpaperInfo {
        let assetIDs = currentAssetIDs()
        let videos = assetIDs.map { assetID in
            VideoInfo(
                assetID: assetID,
                videoPath: "\(videosPath)/\(assetID).mov",
                backupPath: "\(videosPath)/\(assetID).mov.backup"
            )
        }
        return WallpaperInfo(videos: videos)
    }

    /// Reads the asset IDs of the currently-selected aerials from the wallpaper
    /// store index (the same key paths LiveDesk and Backdrop read).
    private func currentAssetIDs() -> [String] {
        guard let plist = NSDictionary(contentsOf: wallpaperIndexPath) else {
            return []
        }

        var assetIDs = Set<String>()

        let keyPaths = [
            "AllSpacesAndDisplays.Idle.Content.Choices",
            "AllSpacesAndDisplays.Desktop.Content.Choices",
            "AllSpacesAndDisplays.Linked.Content.Choices",
            "SystemDefault.Linked.Content.Choices"
        ]

        for keyPath in keyPaths {
            if let choices = plist.value(forKeyPath: keyPath) as? [[String: Any]] {
                for choice in choices {
                    if let configuration = choice["Configuration"] as? Data,
                       let config = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
                       let assetID = config["assetID"] as? String {
                        assetIDs.insert(assetID)
                    }
                }
            }
        }

        return Array(assetIDs)
    }

    // MARK: - Replace / Restore

    /// Replace the lock screen aerials with the given video.
    func replaceLockScreenVideo(with video: Video, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = constructURL(from: video.url) else {
            completion(.failure(LockScreenError.invalidVideo))
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(.failure(LockScreenError.invalidVideo))
            return
        }

        isBusy = true
        lastError = nil

        let run: (() -> Void) = { [weak self] in
            self?.performReplace(with: url) { result in
                DispatchQueue.main.async {
                    self?.isBusy = false
                    switch result {
                    case .success:
                        self?.isReplaced = true
                        completion(.success(()))
                    case .failure(let error):
                        self?.lastError = error.localizedDescription
                        completion(.failure(error))
                    }
                }
            }
        }

        if !hasWritePermission {
            requestWritePermission { [weak self] success in
                guard success else {
                    self?.isBusy = false
                    self?.lastError = "Permission denied — could not take ownership of the aerial store."
                    completion(.failure(LockScreenError.adminPrivilegesRequired))
                    return
                }
                run()
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                run()
            }
        }
    }

    private func performReplace(with videoURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let info = currentWallpaperInfo()

            guard !info.isEmpty else {
                throw LockScreenError.noLockScreenWallpaper
            }
            guard info.allVideosExist else {
                throw LockScreenError.videoNotDownloaded
            }

            // 1. Copy to a temp location so the shell command is a single `cp`.
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("livewallpaper_lock_replace.mov").path
            try? FileManager.default.removeItem(atPath: tempPath)
            try FileManager.default.copyItem(at: videoURL, to: URL(fileURLWithPath: tempPath))

            // 2. Backup (once) + replace every aerial with our video.
            var commands: [String] = []
            for video in info.videos {
                if !video.backupExists {
                    commands.append("cp -p '\(video.videoPath)' '\(video.backupPath)'")
                }
                commands.append("cp '\(tempPath)' '\(video.videoPath)'")
            }

            try runShell(commands.joined(separator: " && "))
            try? FileManager.default.removeItem(atPath: tempPath)

            // 3. Restart WallpaperAgent so it picks up the new videos.
            restartWallpaperAgent()

            // 4. Remember it for the wake re-apply.
            replacedVideoURL = videoURL

            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func restoreLockScreenVideo(completion: @escaping (Result<Void, Error>) -> Void) {
        isBusy = true
        lastError = nil

        let run: (() -> Void) = { [weak self] in
            self?.performRestore { result in
                DispatchQueue.main.async {
                    self?.isBusy = false
                    switch result {
                    case .success:
                        self?.isReplaced = false
                        completion(.success(()))
                    case .failure(let error):
                        self?.lastError = error.localizedDescription
                        completion(.failure(error))
                    }
                }
            }
        }

        if !hasWritePermission {
            requestWritePermission { [weak self] success in
                guard success else {
                    self?.isBusy = false
                    self?.lastError = "Permission denied."
                    completion(.failure(LockScreenError.adminPrivilegesRequired))
                    return
                }
                run()
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                run()
            }
        }
    }

    private func performRestore(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let backupFiles = findAllBackupFiles()
            guard !backupFiles.isEmpty else {
                throw LockScreenError.noBackupFound
            }

            var commands: [String] = []
            for backupPath in backupFiles {
                let originalPath = String(backupPath.dropLast(7)) // Remove ".backup"
                commands.append("cp '\(backupPath)' '\(originalPath)'")
                commands.append("rm '\(backupPath)'")
            }

            try runShell(commands.joined(separator: " && "))
            restartWallpaperAgent()

            replacedVideoURL = nil
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    private func findAllBackupFiles() -> [String] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: videosPath) else {
            return []
        }
        return contents
            .filter { $0.hasSuffix(".mov.backup") }
            .map { "\(videosPath)/\($0)" }
    }

    var canRestore: Bool {
        return !findAllBackupFiles().isEmpty
    }

    var backupCount: Int {
        return findAllBackupFiles().count
    }

    // MARK: - Helpers

    private func runShell(_ command: String) throws {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw LockScreenError.shellFailed(String(data: errorData, encoding: .utf8) ?? "unknown error")
        }
    }

    private func restartWallpaperAgent() {
        let processesToKill = [
            "WallpaperAgent",
            "legacyScreenSaver",
            "idleassetsd"
        ]

        for processName in processesToKill {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments = [processName]
            try? task.run()
            task.waitUntilExit()
        }

        // Give the system a moment to respawn them.
        Thread.sleep(forTimeInterval: 1.0)
    }
}

// MARK: - Errors

enum LockScreenError: LocalizedError {
    case invalidVideo
    case adminPrivilegesRequired
    case noLockScreenWallpaper
    case videoNotDownloaded
    case noBackupFound
    case shellFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidVideo:
            return "The selected video file is missing."
        case .adminPrivilegesRequired:
            return "Administrator privileges are required for this operation."
        case .noLockScreenWallpaper:
            return "No aerial lock-screen wallpaper found. Select an Aerial wallpaper in System Settings first."
        case .videoNotDownloaded:
            return "The system's aerial videos are not downloaded yet. Enable the Aerial wallpaper once so macOS downloads them."
        case .noBackupFound:
            return "No backup found — the lock screen has not been replaced."
        case .shellFailed(let message):
            return "Shell command failed: \(message)"
        }
    }
}
