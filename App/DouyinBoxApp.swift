import SwiftUI
import AVFoundation

enum Tab: Hashable { case parse, play, drama, privacy, library }

@MainActor
final class AppState: ObservableObject {
    @Published var videos: [VideoItem] = []
    @Published var albums: [AlbumItem] = []
    @Published var openAlbum: AlbumItem?
    @Published var dramaSeries: [Series] = []
    @Published var privateSeries: [Series] = []
    @Published var privateUnlocked = false
    @Published var favorites: Set<String> = []
    @Published var current: VideoItem?
    @Published var aspectFill = true
    @Published var order: [String] = []
    @Published var idx = -1
    @Published var selection: Tab = .parse
    @Published var coverVideo: VideoItem?
    @Published var revealUI = false
    @Published var autoAdvance = true
    @Published var renameTarget: VideoItem?
    @Published var renameText = ""
    @Published var exportingID: String?      // 正在提取音频的文件 id
    @Published var extractNote: String?      // 提取结果提示
    @Published var subs: [SubData] = []
    @Published var subsChecking = false
    @Published var tagEditor: VideoItem?
    @Published var islandPending: String?
    @Published var autoReturn = (UserDefaults.standard.object(forKey: "autoReturnV1") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoReturn, forKey: "autoReturnV1") }
    }
    @Published var islandOn = (UserDefaults.standard.object(forKey: "islandOn") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(islandOn, forKey: "islandOn")
            if islandOn { BoxIsland.ensureStandby() } else { BoxIsland.endAll() }
        }
    }

    static let shared = AppState()

    var immersive: Bool { selection == .play && !revealUI }

    // 灵动岛“开始下载”按钮 → 回 App 自动解析+下最优档
    func islandDownload(_ link: String) {
        guard !link.isEmpty else { return }
        selection = .parse
        BoxIsland.update { $0.note = "已回App，即将自动下载" }
        islandPending = link
    }

    private let favKey = "favorites"

    func refresh() { videos = Library.scanRootByDate(); albums = Library.scanAlbums() }
    func refreshDramaSeries() { dramaSeries = Library.series(in: Library.sub("短剧")) }
    func refreshPrivateSeries() { privateSeries = Library.series(in: Library.sub("私密")) }

    // 大库性能：扫描全部挪后台线程，扫完再一次性上屏（打开界面不再卡）
    func refreshSoon() {
        Task { @MainActor in
            let v = await Task.detached(priority: .userInitiated) { Library.scanRootByDate() }.value
            let a = await Task.detached(priority: .userInitiated) { Library.scanAlbums() }.value
            videos = v
            albums = a
        }
    }
    func refreshSeriesSoon() {
        Task { @MainActor in
            let d = await Task.detached(priority: .userInitiated) { Library.series(in: Library.sub("短剧")) }.value
            let p = await Task.detached(priority: .userInitiated) { Library.series(in: Library.sub("私密")) }.value
            dramaSeries = d
            privateSeries = p
        }
    }
    func refreshAsync() async {
        let v = await Task.detached(priority: .userInitiated) { Library.scanRootByDate() }.value
        let a = await Task.detached(priority: .userInitiated) { Library.scanAlbums() }.value
        videos = v
        albums = a
    }
    func refreshSeriesAsync() async {
        let d = await Task.detached(priority: .userInitiated) { Library.series(in: Library.sub("短剧")) }.value
        let p = await Task.detached(priority: .userInitiated) { Library.series(in: Library.sub("私密")) }.value
        dramaSeries = d
        privateSeries = p
    }

    // MARK: 订阅追更
    var subsBadge: Int { subs.reduce(0) { $0 + $1.newCount } }
    func loadSubs() { subs = SubscriptionStore.all() }

    func checkOne(_ s: SubData) async {
        guard let mx = try? await MixAPI.fetch(mixID: s.mixID) else { return }
        var c = s
        c.newCount = SubscriptionStore.pendings(mx).count
        c.lastTotal = mx.eps.count
        c.lastCheck = Date().timeIntervalSince1970
        SubscriptionStore.update(c)
        subs = SubscriptionStore.all()
    }

    func checkSubs() async {
        guard !subsChecking else { return }
        subsChecking = true
        defer { subsChecking = false }
        var list = SubscriptionStore.all()
        for i in 0 ..< list.count {
            if let mx = try? await MixAPI.fetch(mixID: list[i].mixID) {
                list[i].newCount = SubscriptionStore.pendings(mx).count
                list[i].lastTotal = mx.eps.count
                list[i].lastCheck = Date().timeIntervalSince1970
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        SubscriptionStore.save(list)
        subs = list
    }

    func loadFav() { favorites = Set(UserDefaults.standard.stringArray(forKey: favKey) ?? []) }
    private func saveFav() { UserDefaults.standard.set(Array(favorites), forKey: favKey) }

    func toggleFav(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        saveFav()
    }

    func startShuffle() {
        order = videos.map { $0.id }.shuffled()
        idx = -1
        advance()
    }

    func advance() {
        guard !order.isEmpty else { return }
        if idx + 1 < order.count {
            idx += 1
            current = videos.first { $0.id == order[idx] }
        } else {
            startShuffle()
        }
    }

    func back() {
        guard idx - 1 >= 0 else { return }
        idx -= 1
        current = videos.first { $0.id == order[idx] }
    }

    func playInPlace(_ v: VideoItem) { coverVideo = v }

    func deleteVideo(_ v: VideoItem) {
        try? FileManager.default.removeItem(at: v.url)
        ProgressStore.clear(v.id)
        if favorites.contains(v.id) { favorites.remove(v.id); saveFav() }
        if current?.id == v.id { current = nil }
        videos.removeAll { $0.id == v.id }
        albums.removeAll { $0.id == v.url.deletingLastPathComponent().path }
        refreshSeriesSoon()
    }

    func beginRename(_ v: VideoItem) { renameTarget = v; renameText = v.title }

    // 提取音频：原视频旁生成 "标题 音频.m4a"（纯音轨复制/转码，不改动源文件）
    func extractAudio(_ v: VideoItem) {
        guard exportingID == nil, !v.isAudio else { return }
        exportingID = v.id
        Task { @MainActor in
            defer { exportingID = nil; refresh(); refreshDramaSeries(); refreshPrivateSeries() }
            let safe = Naming.sanitize(v.title)
            guard !safe.isEmpty else { return }
            let dest = v.url.deletingLastPathComponent()
                .appendingPathComponent(safe + " 音频.m4a")
            try? FileManager.default.removeItem(at: dest)
            let asset = AVURLAsset(url: v.url)
            guard !asset.tracks(withMediaType: .audio).isEmpty else {
                extractNote = "该视频没有音轨"; return
            }
            guard let session = AVAssetExportSession(asset: asset,
                                                     presetName: AVAssetExportPresetAppleM4A) else { return }
            session.outputURL = dest
            session.outputFileType = .m4a
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
            if session.status == .completed {
                extractNote = "音频已生成，去「库→音频」翻看"
            } else {
                try? FileManager.default.removeItem(at: dest)
                extractNote = "提取失败：\(session.error?.localizedDescription ?? "未知错误")"
            }
        }
    }

    func commitRename() {
        guard let v = renameTarget else { return }
        renameTarget = nil
        let base = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
        let safe = base.components(separatedBy: illegal).joined(separator: " ")
        guard !safe.isEmpty else { return }
        let dest = v.url.deletingLastPathComponent()
            .appendingPathComponent(safe)
            .appendingPathExtension(v.url.pathExtension)
        guard dest.path != v.url.path, !FileManager.default.fileExists(atPath: dest.path) else { return }
        do { try FileManager.default.moveItem(at: v.url, to: dest) } catch { return }
        TagStore.move(old: v.url.path, new: dest.path)
        refresh(); refreshDramaSeries(); refreshPrivateSeries()
    }
}

@main
struct DouyinBoxApp: App {
    @StateObject private var app = AppState.shared
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .onAppear {
                    app.loadFav()
                    app.refreshSoon(); app.refreshSeriesSoon()
                    app.loadSubs()
                    if !app.subs.isEmpty { Task { await app.checkSubs() } }
                    if app.islandOn { BoxIsland.ensureStandby() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $app.selection) {
            ParseView()
                .tabItem { Label("解析", systemImage: "arrow.down.circle") }.tag(Tab.parse)
            PlayerView()
                .tabItem { Label("播放", systemImage: "play.circle") }.tag(Tab.play)
            LibraryView()
                .tabItem { Label("库", systemImage: "square.grid.3x3.fill") }.tag(Tab.library)
            DramaView()
                .tabItem { Label("短剧", systemImage: "film") }.tag(Tab.drama)
                .badge(app.subsBadge)
            PrivateView()
                .tabItem { Label("私密", systemImage: "lock.fill") }.tag(Tab.privacy)
        }
        .fullScreenCover(item: $app.coverVideo) { v in
            InlinePlayer(video: v).environmentObject(app)
        }
        .fullScreenCover(item: $app.openAlbum) { a in
            AlbumViewer(album: a).environmentObject(app)
        }
        .onChange(of: app.selection) { sel in
            if sel != .privacy { app.privateUnlocked = false }
        }
        .onChange(of: scenePhase) { p in
            if p == .background { BoxIsland.ensureStandby() }   // 退后台时岛若被收回则重建
        }
        .alert("重命名",
               isPresented: Binding(get: { app.renameTarget != nil },
                                   set: { if !$0 { app.renameTarget = nil } }),
               presenting: app.renameTarget) { v in
            TextField("新名称", text: Binding(get: { app.renameText }, set: { app.renameText = $0 }))
            Button("取消", role: .cancel) {}
            Button("确定") { app.commitRename() }
        } message: { v in
            Text("当前：\(v.title)")
        }
        .alert("提示",
               isPresented: Binding(get: { app.extractNote != nil },
                                    set: { if !$0 { app.extractNote = nil } })) {
            Button("好") { app.extractNote = nil }
        } message: {
            Text(app.extractNote ?? "")
        }
        .sheet(item: $app.tagEditor) { v in
            TagEditor(video: v)
        }
    }
}
