import SwiftUI

// 容量显示：GB 优先，小文件退 MB/KB
private func fmtGB(_ b: Int) -> String {
    let gb = Double(b) / 1_073_741_824.0
    if gb >= 0.05 { return String(format: "%.2f GB", gb) }
    let mb = Double(b) / 1_048_576.0
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(b) / 1024.0)
}

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort = 0   // 0 最新 1 名称 2 大小
    @State private var seg = 0    // 0视频 1图集 2音频 3收藏
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
        switch seg {
        case 1: return "图集"
        case 2: return "音频"
        case 3: return "收藏"
        default: return "视频库"
        }
    }

    private var poolSizeText: String {
        if seg == 1 {
            return "\(app.albums.count) 本 · \(app.albums.reduce(0) { $0 + $1.count }) 图"
        }
        let list = pool(seg == 0 ? 0 : (seg == 2 ? 2 : 3))   // 统计跟随标签/搜索筛选
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
        NavigationStack {
            VStack(spacing: 0) {
                Picker("视图", selection: $seg) {
                    Text("视频 (\(vidCount))").tag(0)
                    Text("图集 (\(app.albums.count))").tag(1)
                    Text("音频 (\(audCount))").tag(2)
                    Text("收藏 (\(favCount))").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 6)

                Text(poolSizeText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 5).padding(.bottom, 1)

                if seg != 1 { chipRow }

                TabView(selection: $seg) {
                    fileGrid(0).tag(0)
                    albumsPage.tag(1)
                    fileGrid(2).tag(2)
                    fileGrid(3).tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
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
            .onChange(of: seg) { _ in shownLimit = 180 }
            .onChange(of: search) { _ in shownLimit = 180 }
            .onChange(of: filterTags) { _ in shownLimit = 180 }
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
                                Text(Naming.fmtSize(v.size)).font(.caption2).foregroundStyle(.secondary)
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
        ScrollView {
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(app.albums) { a in
                    Button { app.openAlbum = a } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            AlbumThumb(url: a.cover)
                                .frame(height: 150)
                                .background(Color.gray.opacity(0.15))
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
}

private struct RowCover: View {
    let v: VideoItem
    @State private var img: UIImage?
    @State private var landscape = false

    var body: some View {
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
        .frame(height: (landscape && !v.isAudio) ? 96 : 160)   // 横版压扁一行，竖版满格
        .clipped()
        .task(id: v.url) {
            if v.isAudio { return }
            let i = await ThumbCache.shared.image(v.url)
            img = i
            if let s = i?.size, s.height > 0 { landscape = s.width > s.height * 1.05 }
        }
    }
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
        .clipped()
        .task(id: url) { img = await ThumbCache.shared.image(url) }
    }
}
