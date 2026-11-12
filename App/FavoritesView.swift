import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var app: AppState

    private var favs: [VideoItem] { app.videos.filter { app.favorites.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if favs.isEmpty {
                    ContentUnavailableView("还没有收藏",
                                           systemImage: "star",
                                           description: Text("在播放页点 ☆ 收藏当前视频"))
                } else {
                    List {
                        ForEach(favs) { v in
                            HStack {
                                Button { app.playInPlace(v) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(v.title).font(.callout).lineLimit(2).foregroundStyle(.primary)
                                        Text(Naming.fmtSize(v.size)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button { app.toggleFav(v.id) } label: {
                                    Image(systemName: "star.fill").foregroundStyle(.pink)
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle("我的收藏")
            .onAppear { app.refresh() }
            .fullScreenCover(item: $app.coverVideo) { v in
                InlinePlayer(video: v).environmentObject(app)
            }
        }
    }
}
