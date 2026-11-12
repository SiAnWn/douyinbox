import SwiftUI
import LocalAuthentication

struct PrivateView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            Group {
                if !app.privateUnlocked {
                    lockView
                } else if app.privateSeries.isEmpty {
                    ContentUnavailableView("私密为空",
                                           systemImage: "lock",
                                           description: Text("在 文件 › DouyinBox › 私密 下，\n每个合集建一个文件夹，里面放视频"))
                } else {
                    List(app.privateSeries) { s in
                        NavigationLink(value: s) { SeriesRow(series: s) }
                    }
                }
            }
            .navigationTitle(app.privateUnlocked ? "私密 · \(app.privateSeries.count)" : "私密")
            .navigationDestination(for: Series.self) { s in PrivateEpisodes(series: s) }
            .refreshable { app.refreshPrivateSeries() }
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
                                    Thumb(url: v.url).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(v.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                }
                            }.buttonStyle(.plain)
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
