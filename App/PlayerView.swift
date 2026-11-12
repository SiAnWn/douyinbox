import SwiftUI
import AVFoundation

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    private var obs: NSObjectProtocol?

    func load(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }
    func replayCurrent() {
        if let it = player.currentItem { it.seek(to: .zero); player.play() }
    }
    func observeEnd(_ onEnd: @escaping @MainActor () -> Void) {
        removeObs()
        obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { _ in
                Task { @MainActor in onEnd() }
            }
    }
    func removeObs() {
        if let o = obs { NotificationCenter.default.removeObserver(o); obs = nil }
    }
    func pause() { player.pause() }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil) }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { videoLayer.player }
        set { videoLayer.player = newValue }
    }
}

// 只显示播放器；切换由外部调用 load() 完成
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

// MARK: - 播放标签页（随机；自动=播完切下一个，手动=当前循环；右滑出 UI，左滑隐藏）

struct PlayerView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var pc = PlayerController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cur = app.current {
                PlayerSurface(player: pc.player, fill: app.aspectFill)
                    .ignoresSafeArea()

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
            if let c = app.current { pc.load(c.url) }
            pc.observeEnd {
                if app.autoAdvance { goNext() } else { pc.replayCurrent() }
            }
        }
        .onChange(of: app.selection) { sel in
            if sel == .play { pc.player.play() } else { pc.player.pause() }
        }
        .onDisappear { pc.player.pause(); pc.removeObs() }
        .background(TabBarAccessor(hidden: app.immersive))
        .statusBarHidden(app.immersive)
    }

    private func goNext() {
        app.advance()
        if let c = app.current { pc.load(c.url) }
    }
    private func goPrev() {
        app.back()
        if let c = app.current { pc.load(c.url) }
    }

    private var nav: some Gesture {
        DragGesture().onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            if abs(dx) > abs(dy) {
                withAnimation { app.revealUI = (dx > 0) }
            } else {
                if dy < -60 { goNext() }
                else if dy > 60 { goPrev() }
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
            Button { app.autoAdvance.toggle() } label: {
                Text(app.autoAdvance ? "自动" : "手动").font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
            Button { app.aspectFill.toggle() } label: {
                Text(app.aspectFill ? "拉伸" : "适配").font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .padding()
    }

    @ViewBuilder private func bottomBar(_ cur: VideoItem) -> some View {
        Text(cur.title).font(.headline).foregroundStyle(.white).lineLimit(2)
            .multilineTextAlignment(.center)
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

// MARK: - 就地全屏播放器（库/收藏/私密点开，关闭回原页）

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
                .onAppear { pc.load(video.url) }
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

// MARK: - 纯净全屏播放器（私密：无任何 UI，下滑退出，无收藏）

struct CleanPlayer: View {
    let video: VideoItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pc = PlayerController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: pc.player, fill: true)
                .ignoresSafeArea()
                .onAppear { pc.load(video.url) }
                .onDisappear { pc.stop() }
            Color.clear.contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(DragGesture().onEnded { g in
                    if g.translation.height > 80 { dismiss() }
                })
        }
        .statusBarHidden()
    }
}

// MARK: - 按序播放器（短剧：纯画面，上滑下一集，下滑退出，自动播下一集，无收藏）

struct EpisodePlayer: View {
    let items: [VideoItem]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pc = PlayerController()
    @State private var index: Int

    init(items: [VideoItem], start: Int) {
        self.items = items
        _index = State(initialValue: max(0, min(start, max(0, items.count - 1))))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if index < items.count {
                PlayerSurface(player: pc.player, fill: true)
                    .ignoresSafeArea()

                Color.clear.contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(DragGesture().onEnded { g in
                        let dx = g.translation.width, dy = g.translation.height
                        if abs(dy) > abs(dx) {
                            if dy < -60 { next() }
                            else if dy > 60 { dismiss() }   // 下滑退出
                        }
                    })
            }
        }
        .statusBarHidden()
        .onAppear {
            if index < items.count { pc.load(items[index].url) }
            pc.observeEnd { next() }
        }
        .onDisappear { pc.stop(); pc.removeObs() }
    }

    private func next() {
        if index + 1 < items.count {
            index += 1
            pc.load(items[index].url)
        } else {
            pc.pause()   // 最后一集：停住
        }
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
