import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort = 0   // 0 最新 1 名称 2 大小
    @State private var seg = 0    // 0视频 1图集 2音频 3收藏
    @State private var filterTag: String?
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var shown: [VideoItem] {
        var list: [VideoItem]
        switch seg {
        case 2:  list = app.videos.filter { $0.isAudio }
        case 3:  list = app.videos.filter { app.favorites.contains($0.id) }
        default: list = app.videos.filter { !$0.isAudio }
        }
        if let ft = filterTag { list = list.filter { TagStore.tags($0.id).contains(ft) } }
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

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", on: filterTag == nil) { filterTag = nil }
                ForEach(tagChips, id: \.self) { t in
                    chip(t, on: filterTag == t) { filterTag = (filterTag == t ? nil : t) }
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
                .background(on ? Color.accentColor.opacity(0.18) : Color(white: 0.14))
                .foregroundStyle(on ? Color.primary : Color.secondary)
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

                if seg != 1 { chipRow }

                content
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
            .refreshable { app.refresh() }
        }
    }

    @ViewBuilder private var content: some View {
        if seg == 1 {
            albumsGrid
        } else if shown.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(shown) { v in
                        Button { app.playInPlace(v) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RowCover(v: v)
                                    .frame(height: 160)
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
                            Button { app.beginRename(v) } label: { Label("改名", systemImage: "pencil") }
                            Button(role: .destructive) { app.deleteVideo(v) } label: { Label("删除", systemImage: "trash") }
                            Menu {
                                ForEach(TagStore.suggestions, id: \.self) { t in
                                    Button { TagStore.toggle(v.id, t) } label: {
                                        if TagStore.tags(v.id).contains(t) {
                                            Label(t, systemImage: "checkmark")
                                        } else { Text(t) }
                                    }
                                }
                            } label: { Label("标签", systemImage: "tag") }
                        }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if seg == 3 {
            ContentUnavailableView("还没有收藏",
                                   systemImage: "star",
                                   description: Text("播放页点 ☆ 收藏，或长按视频选「收藏」"))
        } else if seg == 2 {
            ContentUnavailableView("还没有音频",
                                   systemImage: "music.note",
                                   description: Text("视频库长按视频 → 提取音频，生成 m4a 存进 App"))
        } else if !search.isEmpty || filterTag != nil {
            ContentUnavailableView("没有匹配", systemImage: "magnifyingglass", description: Text("换个关键词"))
        } else {
            ContentUnavailableView("还没有视频",
                                   systemImage: "square.grid.3x3.fill",
                                   description: Text("去「解析」下载视频"))
        }
    }

    private var albumsGrid: some View {
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
    var body: some View {
        ZStack {
            if v.isAudio {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            } else {
                Thumb(url: v.url)
            }
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
