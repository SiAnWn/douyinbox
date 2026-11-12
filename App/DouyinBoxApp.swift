import SwiftUI

enum Tab: Hashable { case parse, play, fav, drama, privacy, library }

@MainActor
final class AppState: ObservableObject {
    @Published var videos: [VideoItem] = []
    @Published var dramas: [VideoItem] = []
    @Published var privates: [VideoItem] = []
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

    var immersive: Bool { selection == .play && !revealUI }

    private let favKey = "favorites"

    func refresh() { videos = Library.scanRootByDate() }
    func refreshDramas() { dramas = Library.scanNumeric(Library.sub("短剧")) }
    func refreshPrivates() { privates = Library.scan(in: Library.sub("私密")) }

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
}

@main
struct DouyinBoxApp: App {
    @StateObject private var app = AppState()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .onAppear { app.loadFav(); app.refresh(); app.refreshDramas(); app.refreshPrivates() }
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
            FavoritesView()
                .tabItem { Label("收藏", systemImage: "star") }.tag(Tab.fav)
            DramaView()
                .tabItem { Label("短剧", systemImage: "film") }.tag(Tab.drama)
            PrivateView()
                .tabItem { Label("私密", systemImage: "lock.fill") }.tag(Tab.privacy)
            LibraryView()
                .tabItem { Label("库", systemImage: "square.grid.3x3.fill") }.tag(Tab.library)
        }
        .fullScreenCover(item: $app.coverVideo) { v in
            InlinePlayer(video: v).environmentObject(app)
        }
        .onChange(of: app.selection) { sel in
            if sel != .privacy { app.privateUnlocked = false }
        }
    }
}
