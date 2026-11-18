import SwiftUI
import AVFoundation

// MARK: - 坊（v1.10.0）：竖滑本地短剧剧场
// 数据源 = 已下载"剧"库；每部一页，进来播（未看完的）第一集；
// 播完自动连播下一集；底部剧名 + "观看全集›" 直达现成分集连播页。
// 全部本地文件，零流量；进度记忆复用 ProgressStore。
// 门控=每页用背景 GeometryReader 自测屏上占比(global 坐标), 无偏好回传依赖;
// 页高=整屏(UIScreen), 分页严丝合缝不漏下一家。iOS17 安全 API 全家桶。

struct FeedPageItem: Identifiable, Equatable {
    let series: Series
    let eps: [VideoItem]
    var id: String { series.id }
}

struct TheaterFeedView: View {
    @EnvironmentObject var app: AppState
    @State private var pages: [FeedPageItem] = []

    private func rebuild(force: Bool) {
        guard force || pages.isEmpty else { return }
        var list: [FeedPageItem] = []
        for s in app.dramaSeries.shuffled() {
            let eps = Library.videos(in: s.url, numeric: true)
            if !eps.isEmpty { list.append(FeedPageItem(series: s, eps: eps)) }
        }
        pages = list
    }

    var body: some View {
        NavigationStack {
            Group {
                if pages.isEmpty {
                    // 恒渲染宿主+task(lesson 47): 空态也能自己重建
                    ContentUnavailableView("剧场还空的",
                                           systemImage: "film.stack",
                                           description: Text("在 藏→剧 下载短剧后回这里，\n就能像红果一样上下滑换剧刷"))
                        .task { rebuild(force: true) }
                } else {
                    feedScroll
                }
            }
            .navigationTitle("坊 · 本地剧场")
            .toolbar(.hidden, for: .navigationBar)   // 剧场=全幅沉浸, 刷新用下拉
            .toolbar(.hidden, for: .tabBar)          // tab 条也让位, 左上角浮钮换页
            .overlay(alignment: .topLeading) {
                VStack(spacing: 10) {
                    miniJump(Tab.pick, "tray.and.arrow.down")
                    miniJump(Tab.stash, "books.vertical")
                    miniJump(Tab.seal, "seal")
                }
                .padding(.leading, 14)
                .padding(.top, 58)   // 躲开状态栏/岛
            }
            .navigationDestination(for: Series.self) { s in DramaEpisodes(series: s) }
            .onAppear { rebuild(force: false) }
            .refreshable { rebuild(force: true) }
        }
    }

    private func miniJump(_ t: Tab, _ sym: String) -> some View {
        Button { app.selection = t } label: {
            Image(systemName: sym)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.5)))
        }
    }

    private var feedScroll: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(pages) { pg in
                    FeedReel(page: pg)
                        .frame(width: UIScreen.main.bounds.width,
                               height: UIScreen.main.bounds.height)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .ignoresSafeArea()
        .background(Color.black)
    }
}

// 单页：一部剧的一页竖滑视频
struct FeedReel: View {
    let page: FeedPageItem
    @StateObject private var pc = PlayerController()
    @State private var epIdx = 0
    @State private var fill = true
    @State private var loaded = false

    private var cur: VideoItem {
        page.eps[min(epIdx, page.eps.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: pc.player, fill: fill)
                .ignoresSafeArea()

            Color.clear.contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(count: 2) { pc.togglePlay() }   // 播放交互定稿: 双击暂停/恢复

            if !pc.playing && loaded {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 58))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 6)
            }

            VStack {
                Spacer()
                bottomBar
            }
        }
        // 自测可见度: 屏上占比 ≥60% 才开播, 滑走即停 (每页独立, 不依赖父级状态)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { vis(g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global).minY) { _ in vis(g.frame(in: .global)) }
        })
        .onDisappear { pc.stop(); loaded = false }
    }

    private func vis(_ f: CGRect) {
        let h = UIScreen.main.bounds.height
        guard h > 0 else { return }
        let onScreen = min(f.maxY, h) - max(f.minY, 0)
        let frac = max(0, onScreen) / h
        if frac > 0.6 {
            if !loaded {
                loaded = true
                pc.load(cur.url, id: cur.id)
                pc.observeEnd { advance() }
            } else if !pc.playing {
                pc.togglePlay()
            }
        } else if loaded, pc.playing {
            pc.pause()
        }
    }

    private func advance() {
        if epIdx + 1 < page.eps.count {
            epIdx += 1
            pc.load(cur.url, id: cur.id)
        } else {
            pc.pause()
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(page.series.name)
                .font(.title3).bold()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 4)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text("第\(min(epIdx + 1, page.eps.count))集 · 全\(page.eps.count)集")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.7), radius: 3)
                Spacer()
                Button { fill.toggle() } label: {
                    Text(fill ? "裁切" : "完整")
                        .font(.footnote).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.4)))
                }
                Button {
                    app.feedFullIdx = min(epIdx, page.eps.count - 1)
                    app.feedFull = page
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle.fill").font(.caption)
                        Text("观看全集 ›").font(.subheadline.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color(red: 0.15, green: 0.68, blue: 0.42)))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 74)   // tab 条已藏, 只让开底部小横条
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 200)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        )
        .frame(maxWidth: .infinity, alignment: .bottom)
    }
}
