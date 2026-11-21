import SwiftUI
import AVFoundation

// 容量显示：GB 优先，小文件退 MB/KB
private func fmtGB(_ b: Int) -> String {
    let gb = Double(b) / 1_073_741_824.0
    if gb >= 0.05 { return String(format: "%.2f GB", gb) }
    let mb = Double(b) / 1_048_576.0
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(b) / 1024.0)
}

// v1.10.94 方案A第二刀: 内层四段切换器(视频/图集/音频/收藏)废除, 本组件按 kind 参数化
// (0 视频 2 音频 3 收藏); 图集旧"图集_"系统搬去 画 段当"抖音图集"分区;
// 藏 tab 统一一排五段 影|音|藏|画|私, 一屏一段一张网格, 不再俄罗斯套娃
struct LibraryView: View {
    let kind: Int
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort = 0   // 0 最新 1 名称 2 大小
    @State private var filterTags: Set<String> = []   // 多选筛选，任一命中
    @State private var shownLimit = 180   // 分批渲染，几万条也丝滑
    @State private var showNewTag = false
    @State private var newTagName = ""
    @State private var delTagCandidate: String?
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private func pool(_ kind: Int) -> [VideoItem] {
        var list: [VideoItem]
        switch kind {
        case 2:  list = app.videos.filter { $0.isAudio }
        case 3:  list = app.videos.filter { app.favorites.contains($0.id) }
        default: list = app.videos.filter { !$0.isAudio }
        }
        if !filterTags.isEmpty {
            list = list.filter { v in TagStore.tags(v.id).contains { filterTags.contains($0) } }
        }
        if !search.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case 1: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case 2: list.sort { $0.size > $1.size }
        default: list.sort { $0.modDate > $1.modDate }
        }
        return list
    }

    private var vidCount: Int { app.videos.filter { !$0.isAudio }.count }
    private var audCount: Int { app.videos.filter { $0.isAudio }.count }
    private var favCount: Int { app.videos.count { app.favorites.contains($0.id) } }
    private var tagChips: [String] { TagStore.chips(ids: Set(app.videos.map { $0.id })) }

    private var navTitle: String {
        switch kind {
        case 2: return "音频"
        case 3: return "收藏"
        default: return "视频库"
        }
    }

    private var poolSizeText: String {
        let list = pool(kind)   // 统计跟随标签/搜索筛选
        let total = list.reduce(0) { $0 + $1.size }
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()))?[.systemFreeSize] as? Int ?? 0
        let filtered = !filterTags.isEmpty || !search.isEmpty
        let head = filtered ? "筛选出 \(list.count) 个" : "\(list.count) 个"
        return "\(head) · 共 \(fmtGB(total)) · 本机剩 \(fmtGB(free))"
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", on: filterTags.isEmpty) { filterTags = [] }
                ForEach(tagChips, id: \.self) { t in
                    chip(t, on: filterTags.contains(t)) {
                        if filterTags.contains(t) { filterTags.remove(t) } else { filterTags.insert(t) }
                    }
                    .contextMenu {
                        if !TagStore.suggestions.contains(t) {
                            Button(role: .destructive) {
                                delTagCandidate = t
                            } label: { Label("删除这个标签", systemImage: "tag") }
                        }
                    }
                }
                chip("＋ 新建标签", on: false) { showNewTag = true }
                if filterTags.count > 1 {
                    Text("（任一命中）").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 2)
        }
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.footnote)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? Color.accentColor
                               : Color(UIColor.tertiarySystemFill))   // 浅色/深色模式都清晰
                .foregroundStyle(on ? Color.white : Color.primary)
                .clipShape(Capsule())
        }.buttonStyle(.plain)
    }

    var body: some View {
        Group {
            VStack(spacing: 0) {
                Text(poolSizeText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 8).padding(.bottom, 2)

                if kind == 0 { chipRow }   // 标签是视频的事, 音/藏页不摆

                fileGrid(kind)
            }
            .navigationTitle(navTitle)
            .searchable(text: $search, prompt: "搜索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("最新") { sort = 0 }
                        Button("名称") { sort = 1 }
                        Button("大小") { sort = 2 }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
            }
            .refreshable { await app.refreshAsync() }
            .onAppear { shownLimit = 180 }
            .onChange(of: search) { _ in shownLimit = 180 }
            .onChange(of: filterTags) { _ in shownLimit = 180 }
            .onChange(of: sort) { _ in shownLimit = 180 }
            .alert("新建标签", isPresented: $showNewTag) {
                TextField("标签名（12 字内）", text: $newTagName)
                Button("取消", role: .cancel) { newTagName = "" }
                Button("创建") {
                    let t = TagStore.createTag(newTagName)
                    newTagName = ""
                    if !t.isEmpty { filterTags.insert(t) }
                }
            } message: {
                Text("建好立刻出现在这一行；长按视频→标签里即可勾选")
            }
            .alert("删除标签",
                   isPresented: Binding(get: { delTagCandidate != nil },
                                        set: { if !$0 { delTagCandidate = nil } }),
                   presenting: delTagCandidate) { t in
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    TagStore.removeTag(t)
                    filterTags.remove(t)
                    delTagCandidate = nil
                }
            } message: { t in
                Text("「\(t)」将从标签库和所有视频上一起移除")
            }
        }
    }

    // 一个网格页（kind: 0视频 2音频 3收藏）
    @ViewBuilder private func fileGrid(_ kind: Int) -> some View {
        let list = pool(kind)
        let page = Array(list.prefix(shownLimit))
        if list.isEmpty {
            emptyState(kind)
        } else {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(page) { v in
                        Button { app.playInPlace(v) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RowCover(v: v)
                                    .overlay(alignment: .topLeading) {
                                        if app.favorites.contains(v.id) {
                                            Image(systemName: "star.fill")
                                                .font(.caption).foregroundStyle(.pink)
                                                .padding(6)
                                                .background(.black.opacity(0.35), in: Circle())
                                                .padding(4)
                                        }
                                        if app.exportingID == v.id {
                                            Text("提取中…")
                                                .font(.caption2).foregroundStyle(.white)
                                                .padding(4).background(.orange.opacity(0.85), in: Capsule())
                                                .padding(4)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(v.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                SizeLine(v: v)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { app.toggleFav(v.id) } label: {
                                Label(app.favorites.contains(v.id) ? "取消收藏" : "收藏",
                                      systemImage: app.favorites.contains(v.id) ? "star.slash" : "star")
                            }
                            if !v.isAudio {
                                Button { app.extractAudio(v) } label: {
                                    Label("提取音频", systemImage: "music.note.list")
                                }
                                .disabled(app.exportingID != nil && app.exportingID != v.id)
                            }
                            ShareLink(item: v.url) { Label("分享文件", systemImage: "square.and.arrow.up") }
                            Button { app.beginRename(v) } label: { Label("改名", systemImage: "pencil") }
                            Button(role: .destructive) { app.deleteVideo(v) } label: { Label("删除", systemImage: "trash") }
                            Button { app.tagEditor = v } label: {
                                let ts = TagStore.tags(v.id)
                                Label(ts.isEmpty ? "标签（可多选/新建）"
                                                 : "标签 · 已挂 \(ts.count) 个",
                                      systemImage: "tag")
                            }
                        }
                    }
                }
                .padding()
                if list.count > page.count {
                    HStack(spacing: 8) {
                        Spacer()
                        ProgressView()
                        Text("再载 \(min(360, list.count - page.count)) 个…")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        shownLimit += 360
                    }
                }
            }
        }
    }

    @ViewBuilder private func emptyState(_ kind: Int) -> some View {
        if kind == 3 {
            ContentUnavailableView("还没有收藏",
                                   systemImage: "star",
                                   description: Text("播放页点 ☆ 收藏，或长按视频选「收藏」"))
        } else if kind == 2 {
            ContentUnavailableView("还没有音频",
                                   systemImage: "music.note",
                                   description: Text("视频库长按视频 → 提取音频，生成 m4a 存进 App"))
        } else if !search.isEmpty || !filterTags.isEmpty {
            ContentUnavailableView("没有匹配", systemImage: "magnifyingglass", description: Text("换个关键词/少选一个标签"))
        } else {
            ContentUnavailableView("还没有视频",
                                   systemImage: "square.grid.3x3.fill",
                                   description: Text("去「解析」下载视频"))
        }
    }

    private var albumsPage: some View {
        // v1.10.94 旧"图集_"系统已迁至 画 段(GalleryHomeView·抖音图集) — 此段留档勿用
        EmptyView()
    }
    #if false
    private var albumsPageOld: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(app.albums) { a in
                    Button { app.openAlbum = a } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .aspectRatio(0.667, contentMode: .fit)
                                .background(Color.gray.opacity(0.15))
                                .overlay {
                                    AlbumThumb(url: a.cover)
                                        .clipped()
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Text("\(a.count)图")
                                        .font(.caption2).foregroundStyle(.white)
                                        .padding(4).background(.black.opacity(0.5), in: Capsule())
                                        .padding(4)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(a.title).font(.caption).lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            try? FileManager.default.removeItem(at: a.url)
                            app.refresh()
                        } label: { Label("删除整本", systemImage: "trash") }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if app.albums.isEmpty {
                ContentUnavailableView("还没有图集",
                                       systemImage: "photo.stack",
                                       description: Text("解析抖音「图文作品」→ 存入 App"))
            }
        }
    }
    #endif
}

struct CoverTile: View {
    let v: VideoItem
    @State private var img: UIImage?

    var body: some View {
        // 固定 2:3 底座(v1.9.50 同款铁律): 横版视频封面不再撑爆行/错峰, 一律居中裁切
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(0.667, contentMode: .fit)
            .overlay {
                ZStack {
                    Color(white: 0.12)
                    if v.isAudio {
                        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                                       startPoint: .top, endPoint: .bottom)
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    } else if let i = img {
                        Image(uiImage: i).resizable().scaledToFill()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                // v1.10.96 横版卡吃邻案: scaledToFill 的 view frame=按图比例放大(横图撑到2.6倍卡宽),
                // .clipped() 只剪像素不剪点击区 → 透明溢出盖邻卡截胡(点"大哼"播出"画卷" 只能点边缘).
                // 真解=.frame 把 view 尺寸钉回底座 bounds, 点击区立正
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .contentShape(Rectangle())   // 整卡热区=底座 保险栓
            .task(id: v.url) {
                if v.isAudio { return }
                img = await ThumbCache.shared.image(v.url)
            }
    }
}

private struct RowCover: View {
    let v: VideoItem
    var body: some View { CoverTile(v: v) }
}

struct AlbumThumb: View {
    let url: URL?
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            if let i = img {
                Image(uiImage: i).resizable().scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.secondary)
            }
        }
        // v1.10.96 同族补丁: 图集封面也有横图 点击区钉回框内
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) {
            if let u = url, img == nil {
                img = await Task.detached(priority: .utility) {
                    UIImage(contentsOfFile: u.path)
                }.value
            }
        }
    }
}

struct Thumb: View {
    let url: URL
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let i = img {
                Image(uiImage: i).resizable().scaledToFill()
            } else {
                ProgressView().tint(.white)
            }
        }
        // v1.10.96 同 CoverTile: frame 钉死防横图点击区溢出 (剧墙册卡/搜索格全用此件)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) { img = await ThumbCache.shared.image(url) }
    }
}

// ===================== 分辨率角标（库卡片大小旁, 用户点单） =====================
// 每卡读一次视频轨 naturalSize(轻, 只解析 moov), 会话级缓存;
// 6% 容差归一到标准档位(1088 之类编码宏块垫边 -> 1080P)
@MainActor
final class ResCache {
    static let shared = ResCache()
    static var probe = 0
    private var memo: [URL: String] = [:]
    private var inflight: [URL: Task<String, Never>] = [:]
    private let standard = [240, 270, 360, 480, 540, 576, 720, 1080, 1440, 2160, 2880]
    func tag(_ url: URL) async -> String {
        if let s = memo[url] { return s }
        if let t = inflight[url] { return await t.value }
        let std = standard
        let t = Task.detached(priority: .utility) { () -> String in
            let asset = AVURLAsset(url: url)
            let vt = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let tr = vt.first
            guard let tr2 = tr, let sz = try? await tr2.load(.naturalSize) else {
                return "#" + String(vt.count) + "/" + (FileManager.default.fileExists(atPath: url.path) ? "f" : "x")
            }
            let p = Int(round(min(fabs(sz.width), fabs(sz.height))))
            guard p >= 144 else { return "#" + String(Int(sz.width)) + "x" + String(Int(sz.height)) }
            if let c = std.min(by: { abs($0 - p) < abs($1 - p) }), abs(c - p) <= max(2, Int(Double(c) * 0.06)) {
                return "\(c)P"
            }
            return "\(p)P"
        }
        inflight[url] = t
        let r = await t.value
        if Self.probe < 40 { Self.probe += 1; HGTrail.note("res " + r + " | " + url.lastPathComponent) }
        memo[url] = r
        inflight[url] = nil
        return r
    }
}


// 大小·分辨率合一行: 大小永远在, 分辨率读到即追加(单视图单 task, 无嵌套可疑结构)
struct SizeLine: View {
    let v: VideoItem
    @State private var res = ""
    var body: some View {
        Text(Naming.fmtSize(v.size) + (res.isEmpty ? "" : " · " + res))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .task(id: v.url) {
                if res.isEmpty { res = await ResCache.shared.tag(v.url) }
                else if v.isAudio { res = "" }
            }
    }
}
