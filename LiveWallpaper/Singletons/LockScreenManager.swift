//
//  LockScreenManager.swift
//  LiveWallpaper
//
//  Port of the lock-screen aerial mechanism used by Backdrop (Cindori), fixed to
//  use Backdrop's ACTUAL approach: instead of overwriting the system's aerial
//  files in place (which macOS reverts by re-downloading manifest-listed assets),
//  we REGISTER the user's video as a first-class entry in Apple's aerial manifest:
//
//    ~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json
//    ~/Library/Application Support/com.apple.wallpaper/aerials/videos/<id>.mov
//    ~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails/<id>.png
//
//  and repoint every "Linked" (lock screen) choice in the wallpaper store index
//  (Index.plist) at our asset ID. The system then treats it as an official,
//  selectable wallpaper (it even shows up in System Settings > Wallpaper) and
//  never re-downloads over it because the manifest says it lives at a file:// URL.
//

import Foundation
import AppKit
import AVFoundation

class LockScreenManager: ObservableObject {

    static let shared = LockScreenManager()

    // MARK: - Published UI state

    /// Whether our custom aerial is currently registered as the lock screen.
    @Published var isReplaced: Bool = false
    /// True while a replace/restore operation is in flight.
    @Published var isBusy: Bool = false
    /// Last error message, shown in the UI.
    @Published var lastError: String?

    // MARK: - Paths

    private var aerialsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
    }

    private var videosPath: URL {
        aerialsRoot.appendingPathComponent("videos")
    }

    private var thumbnailsPath: URL {
        aerialsRoot.appendingPathComponent("thumbnails")
    }

    private var manifestPath: URL {
        aerialsRoot.appendingPathComponent("manifest/entries.json")
    }

    private var wallpaperIndexPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    // Our custom category/subcategory IDs (LW-prefixed to avoid colliding with
    // Apple's or Backdrop's BD-prefixed registrations).
    private let ourCategoryID = "LW000000-0000-4000-8000-000000000001"
    private let ourSubcategoryID = "LW000000-0000-4000-8000-000000000002"

    // MARK: - Persistence

    private enum Key: String {
        case registeredAssetID = "LockScreenManager.registeredAssetID"
        case registeredVideoPath = "LockScreenManager.registeredVideoPath"
        case originalAssetIDs = "LockScreenManager.originalAssetIDs"
    }

    private var registeredAssetID: String? {
        get { UserDefaults.standard.string(forKey: Key.registeredAssetID.rawValue) }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: Key.registeredAssetID.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.registeredAssetID.rawValue)
            }
        }
    }

    private var registeredVideoPath: String? {
        get { UserDefaults.standard.string(forKey: Key.registeredVideoPath.rawValue) }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: Key.registeredVideoPath.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.registeredVideoPath.rawValue)
            }
        }
    }

    private var originalAssetIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.originalAssetIDs.rawValue) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Key.originalAssetIDs.rawValue) }
    }

    // MARK: - Init

    private init() {
        isReplaced = registeredAssetID != nil
        observeWake()
    }

    /// macOS may re-point the lock screen choices back to default aerials after
    /// wake/unlock on some builds — re-assert our registration when that happens.
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
        guard let assetID = registeredAssetID, isReplaced else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.silentReassert(assetID: assetID)
        }
    }

    private func silentReassert(assetID: String) {
        guard let videoPath = registeredVideoPath else { return }
        do {
            // The system may re-extract its own manifest copy over ours — if our
            // asset entry vanished, re-merge it so the registration survives wake.
            if !manifestContains(assetID: assetID),
               FileManager.default.fileExists(atPath: videoPath) {
                let url = URL(fileURLWithPath: videoPath)
                try mergeIntoManifest(assetID: assetID, displayName: url.deletingPathExtension().lastPathComponent)
            }
            try repointIndexChoices(to: assetID)
            restartWallpaperAgent()
        } catch {
            print("Lock screen re-assert failed: \(error)")
        }
    }

    // MARK: - Permission

    var hasWritePermission: Bool {
        FileManager.default.isWritableFile(atPath: videosPath.path) &&
        FileManager.default.isWritableFile(atPath: thumbnailsPath.path) &&
        FileManager.default.isWritableFile(atPath: manifestPath.path)
    }

    /// One-time setup: take ownership of the aerial store (macOS 14–15 path).
    func requestWritePermission(completion: @escaping (Bool) -> Void) {
        let username = NSUserName()
        let root = aerialsRoot.path
        let script = "do shell script \"chown -R \(username) '\(root)' && chmod -R u+rw '\(root)'\" with administrator privileges"

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

    // MARK: - Register / Restore

    /// Register the given video as the lock screen wallpaper (Backdrop-style).
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
            self?.performRegister(with: url) { result in
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

    private func performRegister(with videoURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            // 1. Snapshot the current aerials asset IDs so we can restore later.
            let currentIDs = currentAssetIDs()
            guard !currentIDs.isEmpty else {
                throw LockScreenError.noLockScreenWallpaper
            }
            originalAssetIDs = currentIDs

            // 2. Generate a fresh asset ID and stage the video + thumbnail.
            let assetID = UUID().uuidString.uppercased()
            let videoDest = videosPath.appendingPathComponent("\(assetID).mov")
            let thumbDest = thumbnailsPath.appendingPathComponent("\(assetID).png")

            try FileManager.default.copyItem(at: videoURL, to: videoDest)

            // Remux with the moov atom at the front (faststart) — otherwise the
            // lock screen player reads the whole file before playback starts
            // (a visible pause on lock). ffmpeg -c copy is a remux, no re-encode.
            faststartVideo(at: videoDest)

            let thumbnail = try makeThumbnail(from: videoURL)
            try thumbnail.write(to: thumbDest)

            // 3. Merge our asset + category into the manifest.
            try mergeIntoManifest(assetID: assetID, displayName: videoURL.deletingPathExtension().lastPathComponent)

            // 4. Repoint every lock screen (Linked) choice at our asset.
            try repointIndexChoices(to: assetID)

            // 5. Clean up Backdrop's dead custom registration (its BD entries
            //    become orphaned once nothing references them anymore).
            try removeBackdropCustomEntries()

            restartWallpaperAgent()
            registeredAssetID = assetID
            registeredVideoPath = videoURL.path
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
            // 1. Put the original asset IDs back into the index.
            let originals = originalAssetIDs
            if !originals.isEmpty {
                try restoreIndexChoices(to: originals)
            }

            // 2. Remove our manifest entry + category.
            if let assetID = registeredAssetID {
                try removeOurManifestEntries(assetID: assetID)
                try? FileManager.default.removeItem(at: videosPath.appendingPathComponent("\(assetID).mov"))
                try? FileManager.default.removeItem(at: thumbnailsPath.appendingPathComponent("\(assetID).png"))
            }

            restartWallpaperAgent()
            registeredAssetID = nil
            registeredVideoPath = nil
            originalAssetIDs = []
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - Manifest (entries.json)

    private func readManifest() throws -> NSMutableDictionary {
        let data = try Data(contentsOf: manifestPath)
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers),
              let dict = obj as? NSMutableDictionary else {
            throw LockScreenError.manifestCorrupt
        }
        return dict
    }

    private func writeManifest(_ dict: NSMutableDictionary) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestPath, options: .atomic)
    }

    private func mergeIntoManifest(assetID: String, displayName: String) throws {
        let manifest = try readManifest()

        let videoFileURL = videosPath.appendingPathComponent("\(assetID).mov").path
        let thumbFileURL = thumbnailsPath.appendingPathComponent("\(assetID).png").path
        let fileScheme = "file://"

        let shotID = "CUSTOM_\(assetID.replacingOccurrences(of: "-", with: "_"))"

        // --- Asset entry (mirrors Backdrop's exact schema) ---
        let asset: [String: Any] = [
            "localizedNameKey": displayName,
            "pointsOfInterest": ["0": "\(shotID)_0"],
            "showInTopLevel": true,
            "accessibilityLabel": displayName,
            "id": assetID,
            "preferredOrder": 0,
            "url-4K-SDR-240FPS": "\(fileScheme)\(videoFileURL)",
            "previewImage": "\(fileScheme)\(thumbFileURL)",
            "includeInShuffle": true,
            "subcategories": [ourSubcategoryID],
            "categories": [ourCategoryID],
            "shotID": shotID
        ]

        // --- Category + subcategory entries ---
        let subcategory: [String: Any] = [
            "preferredOrder": 0,
            "representativeAssetID": assetID,
            "localizedDescriptionKey": "Use LiveWallpaper app to change custom wallpapers",
            "id": ourSubcategoryID,
            "localizedNameKey": "LiveWallpaper",
            "previewImage": "\(fileScheme)\(thumbFileURL)"
        ]

        let category: [String: Any] = [
            "id": ourCategoryID,
            "localizedDescriptionKey": "Use LiveWallpaper app to change custom wallpapers",
            "preferredOrder": 0,
            "previewImage": "\(fileScheme)\(thumbFileURL)",
            "representativeAssetID": assetID,
            "subcategories": [subcategory],
            "localizedNameKey": "LiveWallpaper"
        ]

        // If we're re-registering after a restore, drop any stale LW entry first.
        removeLWEntries(from: manifest)

        if let assets = manifest["assets"] as? NSMutableArray {
            assets.add(asset)
        } else if let assets = manifest["assets"] as? [Any] {
            manifest["assets"] = assets + [asset]
        }

        if let categories = manifest["categories"] as? NSMutableArray {
            categories.add(category)
        } else if let categories = manifest["categories"] as? [Any] {
            manifest["categories"] = categories + [category]
        }

        try writeManifest(manifest)
    }

    private func removeLWEntries(from manifest: NSMutableDictionary) {
        func isOurs(_ dict: [String: Any]) -> Bool {
            let cats = dict["categories"] as? [String] ?? []
            let subcats = dict["subcategories"] as? [String] ?? []
            return cats.contains(ourCategoryID) || subcats.contains(ourSubcategoryID) ||
                   (dict["id"] as? String) == ourCategoryID ||
                   (dict["id"] as? String) == ourSubcategoryID
        }

        if let assets = manifest["assets"] as? [Any] {
            manifest["assets"] = assets.filter { entry in
                guard let e = entry as? [String: Any] else { return true }
                return !isOurs(e)
            }
        }
        if let categories = manifest["categories"] as? [Any] {
            var result: [Any] = []
            for entry in categories {
                guard let e = entry as? [String: Any] else {
                    result.append(entry)
                    continue
                }
                let id = e["id"] as? String
                if id == ourCategoryID || id == ourSubcategoryID { continue }
                if let subs = e["subcategories"] as? [Any] {
                    var copy = e
                    copy["subcategories"] = subs.filter { sub in
                        guard let s = sub as? [String: Any] else { return true }
                        return (s["id"] as? String) != ourSubcategoryID
                    }
                    result.append(copy)
                } else {
                    result.append(entry)
                }
            }
            manifest["categories"] = result
        }
    }

    /// Backdrop registers its custom wallpapers under BD-prefixed category IDs
    /// with file:// asset URLs. Once nothing references them, they're dead weight
    /// (a stale "Backdrop" section in Settings) — remove them and their files.
    private func removeBackdropCustomEntries() throws {
        let manifest = try readManifest()

        let isBackdropCategoryID: (String?) -> Bool = { id in
            guard let id = id else { return false }
            return id.hasPrefix("BD000000-0000-4000-8000-")
        }

        var removedIDs: [String] = []

        if let assets = manifest["assets"] as? [Any] {
            manifest["assets"] = assets.filter { entry in
                guard let e = entry as? [String: Any] else { return true }
                let url = e["url-4K-SDR-240FPS"] as? String ?? ""
                let cats = e["categories"] as? [String] ?? []
                // Remove only custom (file://) assets that belong to a BD category.
                if url.hasPrefix("file://"), cats.contains(where: isBackdropCategoryID) {
                    if let id = e["id"] as? String {
                        removedIDs.append(id)
                    }
                    return false
                }
                return true
            }
        }

        if let categories = manifest["categories"] as? [Any] {
            manifest["categories"] = categories.filter { entry in
                guard let e = entry as? [String: Any] else { return true }
                return !isBackdropCategoryID(e["id"] as? String)
            }
        }

        try writeManifest(manifest)

        // Clean up the orphaned files for the unlisted Backdrop assets.
        for id in removedIDs {
            try? FileManager.default.removeItem(at: videosPath.appendingPathComponent("\(id).mov"))
            try? FileManager.default.removeItem(at: thumbnailsPath.appendingPathComponent("\(id).png"))
        }
    }

    private func removeOurManifestEntries(assetID: String) throws {
        let manifest = try readManifest()
        if let assets = manifest["assets"] as? [Any] {
            manifest["assets"] = assets.filter { entry in
                guard let e = entry as? [String: Any] else { return true }
                return (e["id"] as? String) != assetID && !isOurAsset(e)
            }
        }
        if let categories = manifest["categories"] as? [Any] {
            manifest["categories"] = categories.filter { entry in
                guard let e = entry as? [String: Any] else { return true }
                let id = e["id"] as? String
                return id != ourCategoryID && id != ourSubcategoryID
            }
        }
        try writeManifest(manifest)
    }

    private func isOurAsset(_ entry: [String: Any]) -> Bool {
        let cats = entry["categories"] as? [String] ?? []
        return cats.contains(ourCategoryID)
    }

    // MARK: - Wallpaper index (Index.plist)

    /// Read the asset IDs of every currently-selected aerial (Lock/Linked) choice
    /// by recursively walking the plist (works across macOS 14/15/26 layouts).
    private func currentAssetIDs() -> [String] {
        guard let plist = NSDictionary(contentsOf: wallpaperIndexPath) else {
            return []
        }

        var assetIDs = Set<String>()

        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let provider = dict["Provider"] as? String,
                   provider == "com.apple.wallpaper.choice.aerials",
                   let configuration = dict["Configuration"] as? Data,
                   let config = try? PropertyListSerialization.propertyList(from: configuration, options: [], format: nil),
                   let configDict = config as? [String: Any],
                   let assetID = configDict["assetID"] as? String {
                    assetIDs.insert(assetID)
                }
                for (_, child) in dict {
                    walk(child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child)
                }
            }
        }

        walk(plist)
        return Array(assetIDs)
    }

    /// Repoint every aerials (Linked/lock screen) choice in the index to our asset.
    private func repointIndexChoices(to assetID: String) throws {
        let plistData = try Data(contentsOf: wallpaperIndexPath)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) else {
            throw LockScreenError.indexUnreadable
        }

        // Build fresh dictionaries while walking — mutating a dictionary during
        // its own enumeration traps in Swift.
        func repoint(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var newDict: [String: Any] = [:]
                for (key, child) in dict {
                    newDict[key] = repoint(child)
                }
                if let provider = dict["Provider"] as? String,
                   provider == "com.apple.wallpaper.choice.aerials",
                   let configuration = dict["Configuration"] as? Data,
                   var config = try? PropertyListSerialization.propertyList(from: configuration, options: [], format: nil) as? [String: Any] {
                    config["assetID"] = assetID
                    if let data = try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0) {
                        newDict["Configuration"] = data
                    }
                }
                return newDict
            } else if let array = value as? [Any] {
                return array.map(repoint)
            }
            return value
        }

        let repointed = repoint(plist)
        let data = try PropertyListSerialization.data(fromPropertyList: repointed, format: plistFormat(for: plistData), options: 0)
        try data.write(to: wallpaperIndexPath, options: .atomic)
    }

    /// Restore the original asset IDs to the aerials choices (by choice order).
    private func restoreIndexChoices(to originalIDs: [String]) throws {
        let plistData = try Data(contentsOf: wallpaperIndexPath)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) else {
            throw LockScreenError.indexUnreadable
        }

        var index = 0
        func restore(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var newDict: [String: Any] = [:]
                for (key, child) in dict {
                    newDict[key] = restore(child)
                }
                if let provider = dict["Provider"] as? String,
                   provider == "com.apple.wallpaper.choice.aerials",
                   let configuration = dict["Configuration"] as? Data,
                   var config = try? PropertyListSerialization.propertyList(from: configuration, options: [], format: nil) as? [String: Any] {
                    if index < originalIDs.count {
                        config["assetID"] = originalIDs[index]
                        index += 1
                        if let data = try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0) {
                            newDict["Configuration"] = data
                        }
                    }
                }
                return newDict
            } else if let array = value as? [Any] {
                return array.map(restore)
            }
            return value
        }

        let restored = restore(plist)
        let data = try PropertyListSerialization.data(fromPropertyList: restored, format: plistFormat(for: plistData), options: 0)
        try data.write(to: wallpaperIndexPath, options: .atomic)
    }

    private func manifestContains(assetID: String) -> Bool {
        guard let manifest = try? readManifest(),
              let assets = manifest["assets"] as? [Any] else {
            return false
        }
        return assets.contains { entry in
            guard let e = entry as? [String: Any] else { return false }
            return (e["id"] as? String) == assetID
        }
    }

    /// Preserve the original plist container format (binary vs XML) when rewriting.
    private func plistFormat(for data: Data) -> PropertyListSerialization.PropertyListFormat {
        if data.count >= 8, data.prefix(8).elementsEqual(Data("bplist00".utf8)) {
            return .binary
        }
        return .xml
    }

    // MARK: - Thumbnail

    private func makeThumbnail(from videoURL: URL) throws -> Data {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Some videos have edit lists / no frame exactly at t=0 — try a few
        // candidate times before giving up.
        let candidates: [CMTime] = [
            .zero,
            CMTime(seconds: 0.5, preferredTimescale: 600),
            CMTime(seconds: 1.0, preferredTimescale: 600)
        ]

        for time in candidates {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }
        throw LockScreenError.thumbnailFailed
    }

    // MARK: - Helpers

    /// Remux a video so its moov atom sits at the front of the file (faststart),
    /// using ffmpeg's stream copy (no re-encode, no quality loss).
    private func faststartVideo(at url: URL) {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }

        // Write the temp into the system tmp dir, not the aerial store, so a
        // mid-remux crash can't leave an orphan .faststart.mov in Apple's store.
        // Same APFS volume on macOS, so moveItem still works.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).faststart.mov")
        defer { try? FileManager.default.removeItem(at: temp) }

        let task = Process()
        task.launchPath = ffmpeg
        task.arguments = ["-y", "-v", "error", "-i", url.path, "-c", "copy", "-movflags", "+faststart", temp.path]

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: temp.path) else {
                return
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            // Non-fatal: keep the original copy if the remux fails.
            return
        }
    }

    private func restartWallpaperAgent() {
        for processName in ["WallpaperAgent", "legacyScreenSaver", "idleassetsd"] {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments = [processName]
            try? task.run()
            task.waitUntilExit()
        }
        Thread.sleep(forTimeInterval: 1.0)
    }
}

// MARK: - Errors

enum LockScreenError: LocalizedError {
    case invalidVideo
    case adminPrivilegesRequired
    case noLockScreenWallpaper
    case manifestCorrupt
    case indexUnreadable
    case thumbnailFailed

    var errorDescription: String? {
        switch self {
        case .invalidVideo:
            return "The selected video file is missing."
        case .adminPrivilegesRequired:
            return "Administrator privileges are required for this operation."
        case .noLockScreenWallpaper:
            return "No aerial lock-screen wallpaper found. Select an Aerial wallpaper in System Settings first."
        case .manifestCorrupt:
            return "Could not read Apple's aerial manifest."
        case .indexUnreadable:
            return "Could not read the wallpaper store index."
        case .thumbnailFailed:
            return "Could not generate a thumbnail for the video."
        }
    }
}
