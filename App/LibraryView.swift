import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if app.videos.isEmpty {
                    ContentUnavailableView("还没有视频",
                                           systemImage: "square.grid.3x3.fill",
                                           description: Text("去「解析」下载视频"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(app.videos) { v in
                                Button { app.playInPlace(v) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Thumb(url: v.url)
                                            .frame(height: 160)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(v.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("视频库 · \(app.videos.count)")
            .refreshable { app.refresh() }
        }
    }
}

struct Thumb: View {
    let url: URL
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let i = img {
                Image(uiImage: i).resizable().scaledToFill()
            } else {
                ProgressView().tint(.white)
            }
        }
        .clipped()
        .task(id: url) { img = await ThumbCache.shared.image(url) }
    }
}
