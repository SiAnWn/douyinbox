import SwiftUI

enum Tab: Hashable { case parse, play, fav, library }

@MainActor
final class AppState: ObservableObject {
    @Published var videos: [VideoItem] = []
    @Published var favorites: Set<String> = []
    @Published var current: VideoItem?
    @Published var aspectFill = true
    @Published var order: [String] = []
    @Published var idx = -1
    @Published var exhausted = false
    @Published var selection: Tab = .parse
    @Published var coverVideo: VideoItem?
    @Published var revealUI = false

    var immersive: Bool { selection == .play && !revealUI }

    private let favKey = "favorites"

    func refresh() { videos = Library.scan() }

    func loadFav() { favorites = Set(UserDefaults.standard.stringArray(forKey: favKey) ?? []) }
    private func saveFav() { UserDefaults.standard.set(Array(favorites), forKey: favKey) }

    func toggleFav(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        saveFav()
    }

    func startShuffle() {
        order = videos.map { $0.id }.shuffled()
        idx = -1
        exhausted = false
        advance()
    }

    func advance() {
        guard !order.isEmpty else { return }
        if idx + 1 < order.count {
            idx += 1
            current = videos.first { $0.id == order[idx] }
        } else {
            exhausted = true
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
                .onAppear { app.loadFav(); app.refresh() }
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
            LibraryView()
                .tabItem { Label("库", systemImage: "square.grid.3x3.fill") }.tag(Tab.library)
        }
        .fullScreenCover(item: $app.coverVideo) { v in
            InlinePlayer(video: v).environmentObject(app)
        }
    }
}
