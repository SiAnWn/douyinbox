import SwiftUI
import LocalAuthentication

struct PrivateView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort = 0   // 0 名称 1 数量

    private var shown: [Series] {
        var list = app.privateSeries
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
                if !app.privateUnlocked {
                    lockView
                } else if app.privateSeries.isEmpty {
                    ContentUnavailableView("私密为空",
                                           systemImage: "lock",
                                           description: Text("在 文件 › DouyinBox › 私密 下，\n每个合集建一个文件夹，里面放视频"))
                } else if shown.isEmpty {
                    ContentUnavailableView("没有匹配", systemImage: "magnifyingglass", description: Text("换个关键词"))
                } else {
                    List(shown) { s in
                        NavigationLink(value: s) { SeriesRow(series: s) }
                    }
                    .searchable(text: $search, prompt: "搜索私密")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("名称") { sort = 0 }
                                Button("数量") { sort = 1 }
                            } label: { Image(systemName: "arrow.up.arrow.down") }
                        }
                    }
                }
            }
            .navigationTitle(app.privateUnlocked ? "私密 · \(app.privateSeries.count)" : "私密")
            .navigationDestination(for: Series.self) { s in PrivateEpisodes(series: s) }
            .refreshable { await app.refreshSeriesAsync() }
        }
        .onAppear { if !app.privateUnlocked { authenticate() } }
    }

    private var lockView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("私密内容需要面容验证").font(.headline)
            Button { authenticate() } label: {
                Text("验证面容").padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        let policy: LAPolicy
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            policy = .deviceOwnerAuthentication
        } else {
            app.privateUnlocked = false
            return
        }
        ctx.evaluatePolicy(policy, localizedReason: "查看私密视频") { ok, _ in
            DispatchQueue.main.async { app.privateUnlocked = ok }
        }
    }
}

struct PrivateEpisodes: View {
    let series: Series
    @EnvironmentObject var app: AppState
    @State private var vids: [VideoItem] = []
    @State private var cleanVideo: VideoItem?
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private func load() { vids = Library.videos(in: series.url, numeric: false) }

    var body: some View {
        Group {
            if vids.isEmpty {
                ContentUnavailableView("没有视频", systemImage: "lock", description: Text("该文件夹为空"))
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(vids) { v in
                            Button { cleanVideo = v } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    CoverTile(v: v)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(v.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    Text(Naming.fmtSize(v.size)).font(.caption2).foregroundStyle(.secondary)
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
        .fullScreenCover(item: $cleanVideo) { v in
            CleanPlayer(video: v)
        }
    }
}
