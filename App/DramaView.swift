import SwiftUI

struct DramaView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            Group {
                if app.dramaSeries.isEmpty {
                    ContentUnavailableView("短剧为空",
                                           systemImage: "film",
                                           description: Text("在 文件 › DouyinBox › 短剧 下，\n每部短剧建一个文件夹，里面放各集"))
                } else {
                    List(app.dramaSeries) { s in
                        NavigationLink(value: s) { SeriesRow(series: s) }
                    }
                }
            }
            .navigationTitle("短剧 · \(app.dramaSeries.count)")
            .navigationDestination(for: Series.self) { s in DramaEpisodes(series: s) }
            .refreshable { app.refreshDramaSeries() }
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
