import SwiftUI
import AVFoundation

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    func set(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { videoLayer.player }
        set { videoLayer.player = newValue }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.isUserInteractionEnabled = false
        v.player = player
        v.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.player = player
        uiView.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

// MARK: - 播放标签页（沉浸：右滑显示全部 UI，左滑隐藏，上滑/下滑切换）

struct PlayerView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var pc = PlayerController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cur = app.current {
                PlayerSurface(player: pc.player, fill: app.aspectFill)
                    .id(cur.id)
                    .ignoresSafeArea()
                    .onAppear { pc.set(cur.url) }

                Color.clear.contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(nav)

                if app.revealUI {
                    VStack {
                        topBar(cur)
                        Spacer()
                        bottomBar(cur)
                    }
                    .transition(.opacity)
                }
            } else {
                empty
            }
        }
        .onAppear {
            app.revealUI = false
            app.refresh()
            if app.current == nil && !app.videos.isEmpty { app.startShuffle() }
        }
        .onChange(of: app.selection) { sel in
            if sel == .play { pc.player.play() } else { pc.player.pause() }
        }
        .onDisappear { pc.player.pause() }
        .background(TabBarAccessor(hidden: app.immersive))
        .statusBarHidden(app.immersive)
    }

    private var nav: some Gesture {
        DragGesture().onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            if abs(dx) > abs(dy) {
                withAnimation { app.revealUI = (dx > 0) }
            } else {
                if dy < -60 { app.advance() }
                else if dy > 60 { app.back() }
            }
        }
    }

    @ViewBuilder private func topBar(_ cur: VideoItem) -> some View {
        HStack {
            Button { app.toggleFav(cur.id) } label: {
                Image(systemName: app.favorites.contains(cur.id) ? "star.fill" : "star")
                    .font(.title2).foregroundStyle(.white).shadow(radius: 3)
            }
            Spacer()
            Button { app.aspectFill.toggle() } label: {
                Text(app.aspectFill ? "拉伸" : "适配").font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .padding()
    }

    @ViewBuilder private func bottomBar(_ cur: VideoItem) -> some View {
        VStack(spacing: 12) {
            Text(cur.title).font(.headline).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(.horizontal)
        .padding(.bottom, 56)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.circle").font(.system(size: 54)).foregroundStyle(.white.opacity(0.6))
            Text("还没有视频\n去「解析」下载，或到「库」选择")
                .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
            Button { app.startShuffle() } label: {
                Text("开始随机播放").foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(.white.opacity(0.2)))
            }
        }
        .padding()
    }
}

// MARK: - 就地全屏播放器（库/收藏点开，关闭回原页）

struct InlinePlayer: View {
    let video: VideoItem
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pc = PlayerController()
    @State private var fill = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: pc.player, fill: fill)
                .ignoresSafeArea()
                .onAppear { pc.set(video.url) }
                .onDisappear { pc.stop() }

            Color.clear.contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(DragGesture().onEnded { g in
                    if g.translation.height > 80 { dismiss() }
                })

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.title2).foregroundStyle(.white).shadow(radius: 3)
                    }
                    Spacer()
                    Button { app.toggleFav(video.id) } label: {
                        Image(systemName: app.favorites.contains(video.id) ? "star.fill" : "star")
                            .font(.title2).foregroundStyle(.white).shadow(radius: 3)
                    }
                    Button { fill.toggle() } label: {
                        Text(fill ? "拉伸" : "适配").font(.subheadline).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(.black.opacity(0.45)))
                    }
                }.padding()
                Spacer()
                Text(video.title).font(.headline).foregroundStyle(.white).lineLimit(2).padding()
            }
        }
        .statusBarHidden()
    }
}

// 用 UIKit 直接控制标签栏/状态栏显隐（比 SwiftUI .toolbar 更可靠）
struct TabBarAccessor: UIViewControllerRepresentable {
    let hidden: Bool
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view = UIView(frame: .zero)
        vc.view.backgroundColor = .clear
        return vc
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        DispatchQueue.main.async {
            vc.tabBarController?.tabBar.isHidden = hidden
        }
    }
}
