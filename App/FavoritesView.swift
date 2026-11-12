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
                            HStack(spacing: 10) {
                                Button { app.playInPlace(v) } label: {
                                    HStack(spacing: 10) {
                                        Thumb(url: v.url)
                                            .frame(width: 56, height: 76)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(v.title).font(.callout).lineLimit(2).foregroundStyle(.primary)
                                            Text(Naming.fmtSize(v.size)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
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
        }
    }
}
