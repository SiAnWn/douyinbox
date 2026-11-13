import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort = 0   // 0 最新 1 名称 2 大小
    @State private var favOnly = false
    @State private var filterTag: String?
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var shown: [VideoItem] {
        var list = favOnly ? app.videos.filter { app.favorites.contains($0.id) } : app.videos
        if let ft = filterTag { list = list.filter { TagStore.tags($0.id).contains(ft) } }
        if !search.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case 1: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case 2: list.sort { $0.size > $1.size }
        default: list.sort { $0.modDate > $1.modDate }
        }
        return list
    }

    private var favCount: Int { app.videos.count { app.favorites.contains($0.id) } }
    private var tagChips: [String] { TagStore.chips(ids: Set(app.videos.map { $0.id })) }

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
                Picker("视图", selection: $favOnly) {
                    Text("全部 (\(app.videos.count))").tag(false)
                    Text("收藏 (\(favCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 6)

                chipRow

                content
            }
            .navigationTitle(favOnly ? "收藏" : "视频库")
            .searchable(text: $search, prompt: "搜索视频")
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
        if app.videos.isEmpty {
            ContentUnavailableView("还没有视频",
                                   systemImage: "square.grid.3x3.fill",
                                   description: Text("去「解析」下载视频"))
        } else if favOnly && favCount == 0 {
            ContentUnavailableView("还没有收藏",
                                   systemImage: "star",
                                   description: Text("播放页点 ☆ 收藏，或长按视频选「收藏」"))
        } else if shown.isEmpty {
            ContentUnavailableView("没有匹配", systemImage: "magnifyingglass", description: Text("换个关键词"))
        } else {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(shown) { v in
                        Button { app.playInPlace(v) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Thumb(url: v.url)
                                    .frame(height: 160)
                                    .overlay(alignment: .topLeading) {
                                        if app.favorites.contains(v.id) {
                                            Image(systemName: "star.fill")
                                                .font(.caption).foregroundStyle(.pink)
                                                .padding(6)
                                                .background(.black.opacity(0.35), in: Circle())
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
