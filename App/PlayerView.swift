import SwiftUI
import AVFoundation

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    func set(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
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
        v.player = player
        v.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.player = player
        uiView.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

struct PlayerView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var pc = PlayerController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cur = app.current {
                PlayerSurface(player: pc.player, fill: app.aspectFill)
                    .ignoresSafeArea()
                    .onAppear { pc.set(cur.url) }
                    .onChange(of: cur.id) { _ in pc.set(cur.url) }
                    .gesture(
                        DragGesture().onEnded { g in
                            if g.translation.height < -60 { app.advance() }
                            else if g.translation.height > 60 { app.back() }
                        }
                    )
                VStack {
                    controls(cur)
                    Spacer()
                    bottom(cur)
                }
                .padding(.horizontal, 4)
            } else {
                empty
            }
        }
        .onAppear {
            app.refresh()
            if app.current == nil && !app.videos.isEmpty { app.startShuffle() }
        }
        .onChange(of: app.selection) { sel in
            if sel == .play { pc.player.play() } else { pc.player.pause() }
        }
        .onDisappear { pc.player.pause() }
    }

    @ViewBuilder private func controls(_ cur: VideoItem) -> some View {
        HStack {
            Button { app.toggleFav(cur.id) } label: {
                Image(systemName: app.favorites.contains(cur.id) ? "star.fill" : "star")
                    .font(.title2).foregroundStyle(.white)
                    .shadow(radius: 3)
            }
            Spacer()
            Button { app.aspectFill.toggle() } label: {
                Text(app.aspectFill ? "拉伸" : "适配")
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .padding()
    }

    @ViewBuilder private func bottom(_ cur: VideoItem) -> some View {
        VStack(spacing: 10) {
            Text(cur.title).font(.headline).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Text("↑ 上滑 下一个").font(.caption).foregroundStyle(.white.opacity(0.85))
                Text("↓ 下滑 返回上一个").font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            if app.exhausted {
                Button { app.startShuffle() } label: {
                    Text("已随机完，点此重新随机")
                        .font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(Color(red: 254.0 / 255, green: 44.0 / 255, blue: 85.0 / 255)))
                }
            }
        }
        .padding(.bottom, 40)
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
