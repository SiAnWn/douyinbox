import SwiftUI

struct DramaView: View {
    @EnvironmentObject var app: AppState
    @State private var showEp = false
    @State private var epStart = 0
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if app.dramas.isEmpty {
                    ContentUnavailableView("短剧为空",
                                           systemImage: "film",
                                           description: Text("把短剧放进 文件 › DouyinBox › 短剧 文件夹\n按文件名数字升序排列"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(Array(app.dramas.enumerated()), id: \.element.id) { i, v in
                                Button { epStart = i; showEp = true } label: {
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
            .navigationTitle("短剧 · \(app.dramas.count)")
            .refreshable { app.refreshDramas() }
            .fullScreenCover(isPresented: $showEp) {
                EpisodePlayer(items: app.dramas, start: epStart)
            }
        }
    }
}
