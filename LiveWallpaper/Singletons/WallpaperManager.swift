import Cocoa
import SwiftUI
import AVKit

class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    
    private var window: NSWindow?
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
    
    /// Creates the wallpaper window if not already created
    private func createWallpaperWindow() {

        guard window == nil, let screen = NSScreen.main else { return }

        let newWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))) // Behind icons
        newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        newWindow.ignoresMouseEvents = true
        newWindow.makeKeyAndOrderFront(nil)

        // Use a plain NSView as the content view so snapshot overlays can be added
        // as siblings of the NSHostingView — adding subviews to NSHostingView directly
        // is unsupported on macOS Tahoe and later.
        let wrapper = NSView(frame: screen.frame)
        wrapper.wantsLayer = true
        wrapper.autoresizingMask = [.width, .height]
        newWindow.contentView = wrapper

        self.window = newWindow
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
        
        if window == nil {
            createWallpaperWindow()
        }
        
        let playerItem = AVPlayerItem(url: url)
        
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player!, templateItem: playerItem)
        
        let playerView = PlayerLayerView(player: player!, video: video)
        let hostView = NSHostingView(rootView: playerView)
        animateContentViewTransition(newContentView: hostView)
        
        player!.play()
    }
    

    private func animateContentViewTransition(newContentView: NSView) {
        guard let wrapper = window?.contentView else { return }

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
        window?.contentView = nil
        window = nil
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
              let rootView = window?.contentView else {
            return
        }
        // Take a snapshot of the current frame
        let generator = AVAssetImageGenerator(asset: playerItem.asset)
        generator.appliesPreferredTrackTransform = true
        let time = playerItem.currentTime()
        
        let image = try? generator.copyCGImage(at: time, actualTime: nil)
        let snapshot = image.map { NSImage(cgImage: $0, size: .zero) }


        // Overlay the snapshot to simulate a frozen frame
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
        // Add to root view
        rootView.addSubview(imageView, positioned: .above, relativeTo: nil)
    }
    
    private func removeSnapshot(){
        guard let rootView = window?.contentView else {
            return
        }
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
                self.layer?.contentsGravity = CALayerContentsGravity.resizeAspectFill
                self.layer?.contents = newValue
                self.wantsLayer = true
                
                super.image = newValue
            }
            
            get {
                return super.image
            }
        }
}

