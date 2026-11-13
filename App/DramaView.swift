import SwiftUI

struct DramaView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort = 0   // 0 名称 1 集数
    @State private var showSubs = false

    private var shown: [Series] {
        var list = app.dramaSeries
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case 1: list.sort { $0.count > $1.count }
        default: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.dramaSeries.isEmpty {
                    ContentUnavailableView("短剧为空",
                                           systemImage: "film",
                                           description: Text("在 文件 › DouyinBox › 短剧 下，\n每部短剧建一个文件夹，里面放各集"))
                } else if shown.isEmpty {
                    ContentUnavailableView("没有匹配", systemImage: "magnifyingglass", description: Text("换个关键词"))
                } else {
                    List(shown) { s in
                        NavigationLink(value: s) { SeriesRow(series: s) }
                    }
                }
            }
            .navigationTitle("短剧 · \(app.dramaSeries.count)")
            .searchable(text: $search, prompt: "搜索短剧")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSubs = true } label: {
                        Image(systemName: app.subsBadge > 0 ? "bell.badge.fill" : "bell")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("名称") { sort = 0 }
                        Button("集数") { sort = 1 }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
            }
            .navigationDestination(for: Series.self) { s in DramaEpisodes(series: s) }
            .refreshable { await app.refreshSeriesAsync() }
            .sheet(isPresented: $showSubs) { SubsView().environmentObject(app) }
        }
    }
}

struct SeriesRow: View {
    let series: Series
    var body: some View {
        HStack(spacing: 12) {
            if let c = series.cover {
                Thumb(url: c).frame(width: 60, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Rectangle().fill(Color(white: 0.15)).frame(width: 60, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(series.name).font(.headline).lineLimit(2)
                Text("\(series.count) 集").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DramaEpisodes: View {
    let series: Series
    @EnvironmentObject var app: AppState
    @State private var eps: [VideoItem] = []
    @State private var showEp = false
    @State private var epStart = 0
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private func load() { eps = Library.videos(in: series.url, numeric: true) }

    var body: some View {
        Group {
            if eps.isEmpty {
                ContentUnavailableView("没有视频", systemImage: "film", description: Text("该文件夹为空"))
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(Array(eps.enumerated()), id: \.element.id) { i, v in
                            Button { epStart = i; showEp = true } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Thumb(url: v.url).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(v.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                }
                            }.buttonStyle(.plain)
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
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .refreshable { load() }
        .fullScreenCover(isPresented: $showEp) {
            EpisodePlayer(items: eps, start: epStart)
        }
    }
}
