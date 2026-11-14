import SwiftUI
import AVFoundation

// 每个视频（按路径）记住播放进度，下次续播
enum ProgressStore {
    static func get(_ id: String) -> Double { UserDefaults.standard.double(forKey: "prog_" + id) }
    static func set(_ id: String, _ t: Double) { UserDefaults.standard.set(t, forKey: "prog_" + id) }
    static func clear(_ id: String) { UserDefaults.standard.removeObject(forKey: "prog_" + id) }
}

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1

    private var endObs: NSObjectProtocol?
    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    private var currentID: String?

    func load(_ url: URL, id: String? = nil) {
        saveProgress()
        currentID = id
        currentTime = 0; duration = 0
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let id {
            let t = ProgressStore.get(id)
            if t > 2 {
                statusObs = item.observe(\.status, options: [.new]) { it, _ in
                    if it.status == .readyToPlay {
                        it.seek(to: CMTime(seconds: t, preferredTimescale: 600))
                    }
                }
            }
        }
        player.playImmediately(atRate: rate)
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            guard let self = self, let it = self.player.currentItem else { return }
            let t = CMTimeGetSeconds(it.currentTime())
            let d = CMTimeGetSeconds(it.duration)
            Task { @MainActor in
                if t.isFinite { self.currentTime = t }
                if d.isFinite { self.duration = d }
            }
        }
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
        currentTime = t
    }
    func setRate(_ r: Float) { rate = r; player.rate = r }

    func saveProgress() {
        guard let id = currentID, let it = player.currentItem else { return }
        let t = CMTimeGetSeconds(it.currentTime())
        let d = CMTimeGetSeconds(it.duration)
        guard t.isFinite, d.isFinite, d > 3 else { return }
        ProgressStore.set(id, t >= d - 1.5 ? 0 : t)
    }

    func observeEnd(_ onEnd: @escaping @MainActor () -> Void) {
        removeEnd()
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { _ in
                Task { @MainActor in onEnd() }
            }
    }
    private func removeEnd() { if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil } }
    private func removeTime() {
        if let t = timeObs { player.removeTimeObserver(t); timeObs = nil }
        statusObs?.invalidate(); statusObs = nil
    }

    func pause() { saveProgress(); player.pause() }
    func stop() { saveProgress(); player.pause(); player.replaceCurrentItem(with: nil); removeTime() }
    func removeObs() { removeEnd(); removeTime() }
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

// 细进度条（连续拖动）+ 倍速
struct PlayerScrubber: View {
    @ObservedObject var pc: PlayerController
    @State private var dragging = false
    @State private var dragFrac: CGFloat = 0
    private let rates: [Float] = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75]

    private func cycleRate() {
        let i = rates.firstIndex(of: pc.rate) ?? -1
        pc.setRate(rates[((i + 1) + rates.count) % rates.count])
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.fmt(dragging ? Double(dragFrac) * pc.duration : pc.currentTime))
                .font(.caption2.monospacedDigit()).foregroundStyle(.white)
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let frac = CGFloat(pc.duration > 0
                    ? (dragging ? Double(dragFrac) : min(max(pc.currentTime / pc.duration, 0), 1))
                    : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28)).frame(height: 3)
                    Capsule().fill(Color.white).frame(width: max(0, w * frac), height: 3)
                    Circle().fill(.white)
                        .frame(width: dragging ? 13 : 9, height: dragging ? 13 : 9)
                        .offset(x: w * frac - (dragging ? 6.5 : 4.5))
                        .shadow(radius: 2)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            dragFrac = min(max(g.location.x / w, 0), 1)
                        }
                        .onEnded { g in
                            let f = min(max(g.location.x / w, 0), 1)
                            pc.seek(Double(f) * pc.duration)
                            dragging = false
                        }
                )
            }
            .frame(height: 22)
            Text(Self.fmt(pc.duration))
                .font(.caption2.monospacedDigit()).foregroundStyle(.white)
            Button { cycleRate() } label: {
                Text("\(Self.rateText(Double(pc.rate)))x")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .padding(.horizontal)
    }

    static func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
    static func rateText(_ r: Double) -> String {
        r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
    }
}

// MARK: - 播放标签页

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
            Orient.playerOn()
            app.revealUI = false
            app.refresh()
            if app.current == nil && !app.videos.isEmpty { app.startShuffle() }
            if let c = app.current { pc.load(c.url, id: c.id) }
            pc.observeEnd { if app.autoAdvance { goNext() } else { pc.seek(pc.currentTime) } }
        }
        .onChange(of: app.selection) { sel in
            if sel == .play { pc.player.playImmediately(atRate: pc.rate) } else { pc.pause() }
        }
        .onDisappear { pc.pause(); pc.removeObs(); Orient.playerOff() }
        .background(TabBarAccessor(hidden: app.immersive))
        .statusBarHidden(app.immersive)
    }

    private func goNext() {
        app.advance()
        if let c = app.current { pc.load(c.url, id: c.id) }
    }
    private func goPrev() {
        app.back()
        if let c = app.current { pc.load(c.url, id: c.id) }
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
        VStack(spacing: 10) {
            PlayerScrubber(pc: pc)
            Text(cur.title).font(.headline).foregroundStyle(.white).lineLimit(2)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
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

// MARK: - 就地全屏播放器（库/收藏）

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
                .onAppear { pc.load(video.url, id: video.id) }
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
                PlayerScrubber(pc: pc)
                Text(video.title).font(.headline).foregroundStyle(.white).lineLimit(2).padding()
            }
        }
        .statusBarHidden()
        .onAppear { Orient.playerOn() }
        .onDisappear { Orient.playerOff() }
    }
}

// MARK: - 私密全屏播放器（右滑出 UI）

struct CleanPlayer: View {
    let video: VideoItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pc = PlayerController()
    @State private var showUI = false
    @State private var fill = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: pc.player, fill: fill)
                .ignoresSafeArea()
                .onAppear { pc.load(video.url, id: video.id) }
                .onDisappear { pc.stop() }

            Color.clear.contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(nav)

            if showUI {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.title2).foregroundStyle(.white).shadow(radius: 3)
                        }
                        Spacer()
                        Button { fill.toggle() } label: {
                            Text(fill ? "拉伸" : "适配").font(.subheadline).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(.black.opacity(0.45)))
                        }
                    }.padding()
                    Spacer()
                    PlayerScrubber(pc: pc)
                    Text(video.title).font(.headline).foregroundStyle(.white).lineLimit(2)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!showUI)
    }

    private var nav: some Gesture {
        DragGesture().onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            if abs(dx) > abs(dy) {
                withAnimation { showUI = (dx > 0) }
            } else {
                if dy > 60 { dismiss() }
            }
        }
    }
}

// MARK: - 短剧按序播放器（右滑出 UI；上滑下一集，下滑退出；自动下一集）

struct EpisodePlayer: View {
    let items: [VideoItem]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pc = PlayerController()
    @State private var index: Int
    @State private var showUI = false
    @State private var fill = true

    init(items: [VideoItem], start: Int) {
        self.items = items
        _index = State(initialValue: max(0, min(start, max(0, items.count - 1))))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if index < items.count {
                PlayerSurface(player: pc.player, fill: fill)
                    .ignoresSafeArea()

                Color.clear.contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(nav)

                if showUI {
                    VStack {
                        HStack {
                            Button { dismiss() } label: {
                                Image(systemName: "chevron.down").font(.title2).foregroundStyle(.white).shadow(radius: 3)
                            }
                            Spacer()
                            Text("第 \(index + 1)/\(items.count) 集").font(.subheadline).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(.black.opacity(0.45)))
                            Button { fill.toggle() } label: {
                                Text(fill ? "拉伸" : "适配").font(.subheadline).foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(.black.opacity(0.45)))
                            }
                        }.padding()
                        Spacer()
                        PlayerScrubber(pc: pc)
                        Text(items[index].title).font(.headline).foregroundStyle(.white).lineLimit(2)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                    .transition(.opacity)
                }
            }
        }
        .statusBarHidden(!showUI)
        .onAppear {
            if index < items.count { pc.load(items[index].url, id: items[index].id) }
            pc.observeEnd { next() }
        }
        .onDisappear { pc.stop(); pc.removeObs() }
    }

    private var nav: some Gesture {
        DragGesture().onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            if abs(dx) > abs(dy) {
                withAnimation { showUI = (dx > 0) }
            } else {
                if dy < -60 { next() }
                else if dy > 60 { dismiss() }
            }
        }
    }

    private func next() {
        if index + 1 < items.count {
            index += 1
            pc.load(items[index].url, id: items[index].id)
        } else {
            pc.pause()
        }
    }
}

// 用 UIKit 直接控制标签栏/状态栏显隐
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
