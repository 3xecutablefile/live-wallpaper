//
//  LiveWallpaperApp.swift
//  LiveWallpaper
//


import SwiftUI

@main
struct LiveWallpaperApp: App {
    
    let userSetting = UserSetting.shared
    
    
    var body: some Scene {
//        Window("Wallpaper",id: "MainWindow") {
//            ContentView()
//        }
//        .defaultSize(width:900, height:500)
//        .windowResizability(.contentMinSize) // Respect min frame size
        
        MenuBarExtra("Menu", systemImage: "shippingbox.fill") {
            MenuBarView()
        }
    }
    
    init() {
        runOnLaunch()
        DispatchQueue.main.async {
            if !UserSetting.shared.doNotShowWindow {
                WindowManager.showWindow()
                
            }
        }
    }
    
    func runOnLaunch(){
        print("applaunch \(userSetting.video)")
        WallpaperManager.shared.setWallpaperVideo(video: userSetting.video)
        
    }
    
    
}


struct MenuBarView: View {
    
    @ObservedObject var wallpaperManager = WallpaperManager.shared
    @ObservedObject var userSetting = UserSetting.shared
    @ObservedObject var lockScreenManager = LockScreenManager.shared
    @State private var lockScreenToast: String?
    
    var body: some View {
        VStack {
            Button("Open Main UI") {
                WindowManager.showWindow()
            }
            
            Divider()
            
            Toggle("Ambient Sounds", isOn: $userSetting.mixerEnabled)
                .toggleStyle(.checkbox)
            
            Button {
                wallpaperManager.toggleMute()
            } label: {
                HStack {
                    if wallpaperManager.player?.isMuted == true {
                        Text("Unmute Wallpaper")
                    } else {
                        Text("Mute Wallpaper")
                    }
                    
                }
            }
            .disabled(wallpaperManager.player == nil)
            
            Button {
                wallpaperManager.togglePlaying()
            } label: {
                HStack {
                    if wallpaperManager.player?.rate == 0 {
                        Text("Resume Wallpaper")
                    } else {
                        Text("Pause Wallpaper")
                    }
                    
                }
            }
            .disabled(wallpaperManager.player == nil)
            
            Divider()
            
            // Lock Screen section
            if lockScreenManager.isReplaced {
                Text("Lock Screen: custom video")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button("Restore Original Lock Screen") {
                    restoreLockScreen()
                }
                .disabled(lockScreenManager.isBusy)
            } else {
                Button {
                    setAsLockScreen()
                } label: {
                    if lockScreenManager.isBusy {
                        Text("Working…")
                    } else {
                        Text("Set Current Video as Lock Screen")
                    }
                }
                .disabled(userSetting.video.url.isEmpty || lockScreenManager.isBusy)
                
            if let err = lockScreenManager.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            if let toast = lockScreenToast {
                Text(toast)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Divider()
            
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        
        
    }
    
    private func setAsLockScreen() {
        lockScreenManager.replaceLockScreenVideo(with: userSetting.video) { result in
            switch result {
            case .success:
                lockScreenToast = "Lock screen set ✓"
            case .failure(let error):
                lockScreenToast = error.localizedDescription
            }
        }
    }
    
    private func restoreLockScreen() {
        lockScreenManager.restoreLockScreenVideo { result in
            switch result {
            case .success:
                lockScreenToast = "Lock screen restored ✓"
            case .failure(let error):
                lockScreenToast = error.localizedDescription
            }
        }
    }
    
//    private func openMainWindow() {
//        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "MainWindow" }) {
//            window.makeKeyAndOrderFront(nil)
//            NSApp.activate(ignoringOtherApps: true)
//        } else {
//            openWindow(id: "MainWindow")
//            NSApp.activate(ignoringOtherApps: true)
//        }
//        
//    }
}
