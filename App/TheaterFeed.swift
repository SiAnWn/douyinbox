import SwiftUI
import AVFoundation

// MARK: - 坊（v1.10.0）：竖滑本地短剧剧场
// 数据源 = 已下载"剧"库；每部一页，进来播（未看完的）第一集；
// 播完自动连播下一集；底部剧名 + "观看全集›" 直达现成分集连播页。
// 全部本地文件，零流量；进度记忆复用 ProgressStore。

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { rebuild(force: true) } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .navigationDestination(for: Series.self) { s in DramaEpisodes(series: s) }
            .onAppear { rebuild(force: false) }
            .refreshable { rebuild(force: true) }
        }
    }

    private var feedScroll: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(pages) { pg in
                        FeedReel(page: pg)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .ignoresSafeArea()
            .background(Color.black)
        }
    }
}

// 单页：一部剧的一页竖滑视频
struct FeedReel: View {
    let page: FeedPageItem
    @StateObject private var pc = PlayerController()
    @State private var epIdx = 0
    @State private var fill = true

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

            if !pc.playing {
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
        .onAppear {
            pc.load(cur.url, id: cur.id)
            pc.observeEnd { advance() }
        }
        .onDisappear { pc.stop() }
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
                NavigationLink(value: page.series) {
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
        .padding(.bottom, 96)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        )
        .frame(maxWidth: .infinity, alignment: .bottom)
    }
}
