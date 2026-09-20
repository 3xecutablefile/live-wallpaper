import Cocoa
import SwiftUI
import AVKit

class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    
    private var windows: [NSWindow] = []
    @Published var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    
    private var timer: Timer?
    private var didAutoPaused = false
    private var didFocusPaused = false
    private var focusPauseWorkItem: DispatchWorkItem?

    private var isPlayingBeforeSleep = false
    
    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    // Call the function on the main thread
            DispatchQueue.main.async {
                if isOvercast() {
                    self?.autoPauseVideo()
                } else {
                    self?.autoResumeVideo()
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePauseOnFocusLossSettingChanged),
            name: UserSetting.pauseOnFocusLossChangedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWallpaperPresentationSettingChanged),
            name: UserSetting.wallpaperPresentationChangedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

    } // Singleton
    
    @objc private func handleWake() {
        print("System woke from sleep")
        // Your wake action here
        if isPlayingBeforeSleep {
            print("resume player")
            player?.play()
            objectWillChange.send()
        }
        
    }
    
    @objc private func handleSleep() {
        print("System is about to sleep")
        // Your sleep action here
        if player?.rate != 0 {
            isPlayingBeforeSleep = true
        } else {
            isPlayingBeforeSleep = false
        }
    }
    
    /// Creates wallpaper windows according to current display mode
    private func recreateWallpaperWindows() {
        destroyWallpaperWindows()
        let targetFrames = targetWallpaperFrames()

        for frame in targetFrames {
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true

            let wrapper = NSView(frame: CGRect(origin: .zero, size: frame.size))
            wrapper.wantsLayer = true
            wrapper.autoresizingMask = [.width, .height]
            window.contentView = wrapper
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
    }

    private func destroyWallpaperWindows() {
        for window in windows {
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    private func targetWallpaperFrames() -> [CGRect] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        let sortedFrames = screens.map(\.frame).sorted {
            if $0.minX == $1.minX {
                return $0.minY < $1.minY
            }
            return $0.minX < $1.minX
        }

        if UserSetting.shared.wallpaperDisplayMode == .spanAllDisplays {
            return [sortedFrames.dropFirst().reduce(sortedFrames[0]) { $0.union($1) }]
        }

        return sortedFrames
    }
    
    /// Sets or updates the wallpaper video URL
    func setWallpaperVideo(video: Video) {
        guard let url = constructURL(from: video.url) else {return}
        
        if !isValidMovieFile(at: url){
            return
        }
        
        focusPauseWorkItem?.cancel()
        focusPauseWorkItem = nil
        didAutoPaused = false
        didFocusPaused = false
        for track in player?.currentItem?.tracks ?? [] {
            removeSnapshot()
            track.isEnabled = true
        }
        
        recreateWallpaperWindows()
        
        let playerItem = AVPlayerItem(url: url)
        
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player!, templateItem: playerItem)
        
        attachPlayerViews(video: video)
        
        player!.play()
    }
    
    private func attachPlayerViews(video: Video) {
        guard let player else { return }
        for window in windows {
            let playerView = PlayerLayerView(player: player, video: video)
            let hostView = NSHostingView(rootView: playerView)
            animateContentViewTransition(in: window, newContentView: hostView)
        }
    }

    private func animateContentViewTransition(in window: NSWindow, newContentView: NSView) {
        guard let wrapper = window.contentView else { return }

        newContentView.wantsLayer = true
        newContentView.alphaValue = 0
        newContentView.frame = wrapper.bounds
        newContentView.autoresizingMask = [.width, .height]

        // Insert below any snapshot overlay so it remains visible during transition
        let snapshot = wrapper.subviews.first { $0.identifier?.rawValue == "SnapshotOverlay" }
        if let snapshot {
            wrapper.addSubview(newContentView, positioned: .below, relativeTo: snapshot)
        } else {
            wrapper.addSubview(newContentView)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wrapper.subviews.forEach { view in
                if view !== newContentView && view.identifier?.rawValue != "SnapshotOverlay" {
                    view.animator().alphaValue = 0
                }
            }
            newContentView.animator().alphaValue = 1
        } completionHandler: {
            wrapper.subviews.forEach { view in
                if view !== newContentView && view.identifier?.rawValue != "SnapshotOverlay" {
                    view.removeFromSuperview()
                }
            }
        }
    }
    
    /// Mute or unmute the wallpaper video
    func toggleMute() {
        
        if let player = player {
            player.isMuted.toggle()
            
            for track in player.currentItem?.tracks ?? [] {
                if track.assetTrack?.hasMediaCharacteristic(.audible) == true {
                    track.isEnabled = !player.isMuted
                }
            }
        }
        
        
        objectWillChange.send()
    }
    
    func togglePlaying() {
        if player?.rate == 0 {
            player?.play()
        } else {
            player?.pause()
        }
        objectWillChange.send()
    }
    
    func destroy() {
        focusPauseWorkItem?.cancel()
        focusPauseWorkItem = nil
        didAutoPaused = false
        didFocusPaused = false
        looper = nil
        player?.removeAllItems()
        player = nil
        destroyWallpaperWindows()
    }
    
    private func autoPauseVideo() {
        guard UserSetting.shared.powerSaver && !didAutoPaused else { return }
        for track in player?.currentItem?.tracks ?? [] {
            if track.assetTrack?.hasMediaCharacteristic(.visual) == true {
                didAutoPaused = true
                if !didFocusPaused {
                    takeSnapshot()
                    track.isEnabled = false
                }
            }
        }
    }

    private func autoResumeVideo() {
        guard didAutoPaused else { return }
        didAutoPaused = false
        guard !didFocusPaused else { return }
        player?.currentItem?.tracks.forEach { $0.isEnabled = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.removeSnapshot()
        }
    }

    @objc private func handleAppActivation(_ notification: Notification) {
        guard UserSetting.shared.pauseOnFocusLoss else { return }

        let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleId = activated?.bundleIdentifier ?? ""
        let isDesktop = bundleId == "com.apple.finder"
        let isSelf = bundleId == Bundle.main.bundleIdentifier

        if isDesktop || isSelf {
            focusPauseWorkItem?.cancel()
            focusPauseWorkItem = nil
            focusResumeVideo()
        } else {
            focusPauseWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.focusPauseVideo()
            }
            focusPauseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
    }

    @objc private func handlePauseOnFocusLossSettingChanged() {
        if !UserSetting.shared.pauseOnFocusLoss {
            focusPauseWorkItem?.cancel()
            focusPauseWorkItem = nil
            focusResumeVideo()
        }
    }

    @objc private func handleWallpaperPresentationSettingChanged() {
        guard player != nil else { return }
        recreateWallpaperWindows()
        attachPlayerViews(video: UserSetting.shared.video)
    }

    @objc private func handleScreenConfigurationChanged() {
        guard player != nil else { return }
        recreateWallpaperWindows()
        attachPlayerViews(video: UserSetting.shared.video)
    }

    private func focusPauseVideo() {
        guard !didFocusPaused else { return }
        for track in player?.currentItem?.tracks ?? [] {
            if track.assetTrack?.hasMediaCharacteristic(.visual) == true {
                didFocusPaused = true
                if !didAutoPaused {
                    takeSnapshot()
                    track.isEnabled = false
                }
            }
        }
    }

    private func focusResumeVideo() {
        guard didFocusPaused else { return }
        didFocusPaused = false
        guard !didAutoPaused else { return }
        player?.currentItem?.tracks.forEach { $0.isEnabled = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.removeSnapshot()
        }
    }
    
    private func takeSnapshot(){
        guard let playerItem = player?.currentItem,
              !windows.isEmpty else {
            return
        }
        // Take a snapshot of the current frame
        let generator = AVAssetImageGenerator(asset: playerItem.asset)
        generator.appliesPreferredTrackTransform = true
        let time = playerItem.currentTime()
        
        let image = try? generator.copyCGImage(at: time, actualTime: nil)
        let snapshot = image.map { NSImage(cgImage: $0, size: .zero) }


        // Overlay the snapshot to simulate a frozen frame
        for rootView in windows.compactMap(\.contentView) {
            let imageView = NSImageViewFill()
            imageView.image = snapshot
            imageView.frame = rootView.bounds
            imageView.autoresizingMask = [.width, .height]
            imageView.identifier = NSUserInterfaceItemIdentifier("SnapshotOverlay")
            
            let showDarkLayer: Bool = {
                guard UserSetting.shared.adaptiveMode else { return false }

                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                ? true: false
            }()
            
            if showDarkLayer {
                imageView.layer?.addSublayer(createAdaptiveDarkModeOverlay(rect: rootView.bounds, characteristics: UserSetting.shared.video.attrs))
            }
            rootView.addSubview(imageView, positioned: .above, relativeTo: nil)
        }
    }
    
    private func removeSnapshot(){
        let rootViews = windows.compactMap(\.contentView)
        guard !rootViews.isEmpty else {
            return
        }
        for rootView in rootViews {
            for subview in rootView.subviews {
                if subview.identifier?.rawValue == "SnapshotOverlay" {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.5
                        subview.animator().alphaValue = 0
                    }, completionHandler: {
                        if subview.superview != nil {
                            subview.removeFromSuperview()
                        }
                    })
                }
            }
        }
    }
    
    
}



struct PlayerWrapper: NSViewRepresentable {
    let playerView: AVPlayerView
    
    func makeNSView(context: Context) -> AVPlayerView {
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}


class NSImageViewFill : NSImageView {
        
        open override var image: NSImage? {
            set {
                self.layer = CALayer()
                let gravity: CALayerContentsGravity
                switch UserSetting.shared.wallpaperScalingMode {
                case .fill:
                    gravity = .resizeAspectFill
                case .fit:
                    gravity = .resizeAspect
                case .stretch:
                    gravity = .resize
                }
                self.layer?.contentsGravity = gravity
                self.layer?.contents = newValue
                self.wantsLayer = true
                
                super.image = newValue
            }
            
            get {
                return super.image
            }
        }
}
