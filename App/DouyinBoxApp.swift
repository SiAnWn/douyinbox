import SwiftUI

enum Tab: Hashable { case parse, play, drama, privacy, library }

@MainActor
final class AppState: ObservableObject {
    @Published var videos: [VideoItem] = []
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

    var immersive: Bool { selection == .play && !revealUI }

    private let favKey = "favorites"

    func refresh() { videos = Library.scanRootByDate() }
    func refreshDramaSeries() { dramaSeries = Library.series(in: Library.sub("短剧")) }
    func refreshPrivateSeries() { privateSeries = Library.series(in: Library.sub("私密")) }

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
        refresh(); refreshDramaSeries(); refreshPrivateSeries()
    }

    func beginRename(_ v: VideoItem) { renameTarget = v; renameText = v.title }

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
        try? FileManager.default.moveItem(at: v.url, to: dest)
        refresh(); refreshDramaSeries(); refreshPrivateSeries()
    }
}

@main
struct DouyinBoxApp: App {
    @StateObject private var app = AppState()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .onAppear { app.loadFav(); app.refresh(); app.refreshDramaSeries(); app.refreshPrivateSeries() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
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
            PrivateView()
                .tabItem { Label("私密", systemImage: "lock.fill") }.tag(Tab.privacy)
        }
        .fullScreenCover(item: $app.coverVideo) { v in
            InlinePlayer(video: v).environmentObject(app)
        }
        .onChange(of: app.selection) { sel in
            if sel != .privacy { app.privateUnlocked = false }
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
    }
}
