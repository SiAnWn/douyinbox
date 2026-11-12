import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort = 0   // 0 最新 1 名称 2 大小
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var shown: [VideoItem] {
        var list = app.videos
        if !search.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case 1: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case 2: list.sort { $0.size > $1.size }
        default: list.sort { $0.modDate > $1.modDate }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.videos.isEmpty {
                    ContentUnavailableView("还没有视频",
                                           systemImage: "square.grid.3x3.fill",
                                           description: Text("去「解析」下载视频"))
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
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(v.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { app.beginRename(v) } label: { Label("改名", systemImage: "pencil") }
                                    Button(role: .destructive) { app.deleteVideo(v) } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("视频库 · \(app.videos.count)")
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
