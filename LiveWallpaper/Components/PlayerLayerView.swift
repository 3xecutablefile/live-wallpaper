//
//  WallpaperPlayer.swift
//  LiveWallpaper
//
import AppKit
import AVFoundation
import SwiftUI

class CustomPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    
    private var appearanceObserver: NSKeyValueObservation?
    private var darkLayer = CALayer()
    
    let player:AVPlayer
    let video:Video
    

    init(player: AVPlayer, video: Video) {
        self.player = player
        self.video = video
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        playerLayer.player = player
        playerLayer.backgroundColor = NSColor.clear.cgColor

        layer?.addSublayer(playerLayer)
        
        print(video.attrs)
        
        darkLayer = createAdaptiveDarkModeOverlay(rect: playerLayer.bounds, characteristics: video.attrs)
        playerLayer.addSublayer(darkLayer)

        updateOverlay()

        // KVO for appearance
        appearanceObserver = observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.updateOverlay()
        }

        // Observe user setting change
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateOverlay),
            name: UserSetting.adaptiveModeChangedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateVideoGravity),
            name: UserSetting.wallpaperPresentationChangedNotification,
            object: nil
        )
        updateVideoGravity()
    }
    
    
    deinit {
        appearanceObserver?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func updateOverlay() {
        
        let showDarkLayer: Bool = {
            guard UserSetting.shared.adaptiveMode else { return false }

            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
            ? true: false
        }()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        darkLayer.isHidden = !showDarkLayer
        CATransaction.commit()

    }

    @objc func updateVideoGravity() {
        switch UserSetting.shared.wallpaperScalingMode {
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
        case .fit:
            playerLayer.videoGravity = .resizeAspect
        case .stretch:
            playerLayer.videoGravity = .resize
        }
    }

    override func layout() {
        super.layout()
        updateVideoGravity()
        playerLayer.frame = bounds
        darkLayer.frame = bounds
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let video: Video

    func makeNSView(context: Context) -> NSView {
        return CustomPlayerView(player: player, video: video)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let playerView = nsView as? CustomPlayerView else { return }
        playerView.updateVideoGravity()
    }
}
