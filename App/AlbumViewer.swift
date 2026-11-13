import SwiftUI
import UIKit

// 图集翻看器：左右滑动看图，底部页码，右上分享原图
struct AlbumViewer: View {
    let album: AlbumItem
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var idx = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if files.isEmpty {
                    ContentUnavailableView("图片不见了", systemImage: "photo",
                                           description: Text("文件夹可能被删"))
                } else {
                    TabView(selection: $idx) {
                        ForEach(Array(files.enumerated()), id: \.offset) { i, u in
                            PageImage(url: u).tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .navigationTitle(files.isEmpty ? album.title : "第 \(idx + 1)/\(files.count) 图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if idx < files.count {
                            ShareLink(item: files[idx]) { Label("分享这张", systemImage: "square.and.arrow.up") }
                        }
                        Button(role: .destructive) {
                            appDelete()
                        } label: { Label("删除整本", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .onAppear {
            files = Library.imageFiles(in: album.url)
            idx = 0
        }
    }

    @EnvironmentObject private var app: AppState
    private func appDelete() {
        try? FileManager.default.removeItem(at: album.url)
        app.openAlbum = nil
        app.refresh()
    }
}

private struct PageImage: View {
    let url: URL
    @State private var img: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        Group {
            if let i = img {
                Image(uiImage: i)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(i.size, contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = min(max(v, 1), 4) }
                            .onEnded { _ in
                                if scale <= 1.05 { scale = 1; offset = .zero }
                            }
                    )
            } else {
                ProgressView().tint(.white)
            }
        }
        .padding(8)
        .task {
            if img == nil {
                img = await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: url.path)
                }.value
            }
        }
    }
}
