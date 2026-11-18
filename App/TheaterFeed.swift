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
        .onAppear { app.revealUI = false; rebuild(force: false) }
        .onChange(of: app.dramaSeries.count) { _ in rebuild(force: true) }  // 冷启动扫描晚到自愈
        // 与老映同款沉浸体系: 右滑唤回 tab 条, 左滑隐藏(手势在 FeedReel 里); 空态不藏 tab 条
        .background(TabBarAccessor(hidden: app.immersive && !pages.isEmpty))
        .statusBarHidden(app.immersive && !pages.isEmpty)
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
    @EnvironmentObject var app: AppState
    @StateObject private var pc = PlayerController()
    @State private var epIdx = 0
    @State private var fill = true
    @State private var loaded = false
    @State private var frac: Double = 0
    @State private var metaLine = ""
    @State private var metaDesc = ""
    @State private var showDesc = false
    @State private var dmAll: [Int: [DMItem]] = [:]
    @State private var dmItems: [DMItem] = []

    private var cur: VideoItem {
        page.eps[min(epIdx, page.eps.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: pc.player, fill: fill)
                .ignoresSafeArea()

            DanmakuLayer(pc: pc, items: dmItems)   // 离线弹幕(档案落盘后零流量)
                .ignoresSafeArea()

            Color.clear.contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(count: 2) { pc.togglePlay() }   // 播放交互定稿: 双击暂停/恢复

            // 横滑显隐只挂左右边缘窄条: 全屏拖拽手势会干扰分页滚动(两版实测), 边缘条=系统级姿势
            HStack {
                Color.clear.frame(width: 30).contentShape(Rectangle()).gesture(edgeNav())
                Spacer(minLength: 0)
                Color.clear.frame(width: 30).contentShape(Rectangle()).gesture(edgeNav())
            }
            .frame(height: UIScreen.main.bounds.height * 0.62)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()

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
                .onAppear {
                    let pcm = pc
                    app.reelPausers[page.id] = { if pcm.playing { pcm.pause() } }
                    vis(g.frame(in: .global))
                }
                .onChange(of: g.frame(in: .global).minY) { _ in vis(g.frame(in: .global)) }
        })
        .onChange(of: app.selection) { s in
            if s != .feed {
                if loaded, pc.playing { pc.pause() }
            } else if loaded, frac > 0.6, !pc.playing {
                app.muteReels(except: page.id)
                pc.togglePlay()
            }
        }
        // 观看全集浮层盖上来时坊页必须闭嘴(fullScreenCover 不触发 onDisappear)
        .onChange(of: app.feedFull?.id) { v in
            if v != nil {
                if loaded, pc.playing { pc.pause() }
            } else if loaded, frac > 0.6, !pc.playing {
                app.muteReels(except: page.id)
                pc.togglePlay()
            }
        }
        .onDisappear {
            app.reelPausers.removeValue(forKey: page.id)
            pc.stop(); loaded = false
        }
        .sheet(isPresented: $showDesc) {
            VStack(alignment: .leading, spacing: 12) {
                Text(page.series.name).font(.headline)
                if !metaLine.isEmpty {
                    Text(metaLine).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(metaDesc.isEmpty ? "暂无简介" : metaDesc)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("关闭") { showDesc = false }
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .presentationDetents([.medium, .large])
        }
    }

    // 边缘窄条横滑: 右滑唤回 tab 条/信息, 左滑隐藏(与老映方向语义一致)
    private func edgeNav() -> some Gesture {
        DragGesture(minimumDistance: 12).onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            guard abs(dx) > abs(dy), abs(dx) > 40 else { return }
            withAnimation { app.revealUI = (dx > 0) }
        }
    }

    private func vis(_ f: CGRect) {
        let h = UIScreen.main.bounds.height
        guard h > 0 else { return }
        let onScreen = min(f.maxY, h) - max(f.minY, 0)
        frac = max(0, onScreen) / h
        // 互斥音响: 过 60% 即开播并点名其余全部闭嘴(阈值单独挡不住两页同时过线), 掉到 45% 才停防抖
        if frac > 0.6 {
            if !loaded {
                loaded = true
                app.muteReels(except: page.id)
                pc.load(cur.url, id: cur.id)
                pc.observeEnd { advance() }
            } else if !pc.playing {
                app.muteReels(except: page.id)
                pc.togglePlay()
            }
        } else if frac < 0.45, loaded, pc.playing {
            pc.pause()
        }
    }

    private func advance() {
        if epIdx + 1 < page.eps.count {
            epIdx += 1
            dmItems = dmAll[epIdx + 1] ?? []
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
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.7), radius: 3)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Text("第\(min(epIdx + 1, page.eps.count))集 · 全\(page.eps.count)集")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.7), radius: 3)
                Spacer()
                if !metaDesc.isEmpty {
                    Button { showDesc = true } label: {
                        Text("简介")
                            .font(.footnote).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(.black.opacity(0.4)))
                    }
                }
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
        .task(id: page.id) {   // 底条恒渲染宿主挂 task(lesson 47): 档案有则显
            let m = SeriesMetaStore.load(page.series.url)
            metaLine = SeriesMetaStore.line(m)
            metaDesc = m?.desc ?? ""
            dmAll = DanmakuStore.loadEps(page.series.url) ?? [:]
            dmItems = dmAll[epIdx + 1] ?? []
        }
    }
}
