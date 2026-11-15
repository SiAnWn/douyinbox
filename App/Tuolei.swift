import SwiftUI
import Photos

// MARK: - 图叻：网页聚图引擎 v1（通吃模式：懒加载滚动 → DOM 全量聚图 → 预览勾选 → 批量入库）

struct TuoleiHit: Identifiable {
    let id = UUID()
    let title: String
    let urls: [String]
    let page: String
}

enum TuoleiJS {
    // async IIFE：先分段滚到底喂懒加载，再收 <img> + 直链 <a>，去重保序，剔小图
    static let collect = """
    (async () => {
      for (let i = 0; i < 24; i++) {
        window.scrollBy(0, innerHeight * 0.9);
        await new Promise(r => setTimeout(r, 280));
        if ((window.innerHeight + window.scrollY) >= document.body.scrollHeight - 12) break;
      }
      window.scrollTo(0, 0);
      await new Promise(r => setTimeout(r, 250));
      const seen = new Set(); const urls = [];
      for (const im of document.images) {
        let s = im.currentSrc || im.src || '';
        if (!s || s.startsWith('data:')) continue;
        try { s = new URL(s, location.href).href.split('#')[0]; } catch (e) { continue; }
        if (!/^https?:/i.test(s)) continue;
        const w = im.naturalWidth || im.width || 0, h = im.naturalHeight || im.height || 0;
        if (w && w < 220 && h < 220) continue;
        if (seen.has(s)) continue;
        seen.add(s); urls.push(s);
      }
      for (const a of document.links) {
        const h0 = (a.href || '').split('#')[0];
        if (/\\.(jpe?g|png|webp|gif)(\\?[^#]*)?$/i.test(h0) && !seen.has(h0)) { seen.add(h0); urls.push(h0); }
      }
      return JSON.stringify({ t: (document.title || location.hostname).trim(), u: urls, page: location.href });
    })()
    """
}

// MARK: - 预览勾选面板

struct TuoleiSheet: View {
    let hit: TuoleiHit
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var sel: Set<Int>
    @State private var dest = 0            // 0=画廊 1=系统相册
    @State private var running = false
    @State private var done = 0
    @State private var failed = 0

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    init(hit: TuoleiHit) {
        self.hit = hit
        _name = State(initialValue: String(hit.title.prefix(40)))
        _sel = State(initialValue: Set(0..<hit.urls.count))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("图集名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                    Text("\(sel.count)/\(hit.urls.count)")
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }.padding([.horizontal, .top], 14)

                Picker("", selection: $dest) {
                    Text("存画廊").tag(0)
                    Text("存系统相册").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(14)

                ScrollView {
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(0..<hit.urls.count, id: \.self) { i in
                            ZStack(alignment: .topTrailing) {
                                AsyncImage(url: URL(string: hit.urls[i])) { ph in
                                    switch ph {
                                    case .success(let img): img.resizable().scaledToFill()
                                    case .failure: Color.gray.opacity(0.15)
                                    default: Color.gray.opacity(0.08)
                                    }
                                }
                                .frame(height: 108).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                Image(systemName: sel.contains(i)
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(sel.contains(i) ? Color.accentColor : Color.secondary)
                                    .padding(5)
                            }
                            .onTapGesture {
                                if sel.contains(i) { sel.remove(i) } else { sel.insert(i) }
                            }
                        }
                    }.padding(.horizontal, 10)
                }

                HStack(spacing: 14) {
                    Button("全选") { sel = Set(0..<hit.urls.count) }
                    Button("全不选") { sel = [] }
                    Button("反选") {
                        var s = Set<Int>()
                        for i in 0..<hit.urls.count where !sel.contains(i) { s.insert(i) }
                        sel = s
                    }
                    Spacer()
                    if running {
                        ProgressView("\(done)/\(sel.count)").controlSize(.small)
                        if failed > 0 { Text("失败 \(failed)").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Button {
                            run()
                        } label: {
                            Text("下载 \(sel.count) 张")
                                .font(.headline)
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Capsule().fill(.tint))
                                .foregroundStyle(.white)
                        }
                        .disabled(sel.isEmpty)
                    }
                }
                .buttonStyle(.borderless).font(.callout)
                .padding(16)
            }
            .navigationTitle("图叻 · 聚到 \(hit.urls.count) 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { if !running { dismiss() } }
                }
            }
        }
    }

    private func run() {
        running = true
        Task { @MainActor in
            var savedFiles: [(Data, String)] = []
            let ext = { (u: String) -> String in
                let p = u.split(separator: "?")[0]
                for e in ["png", "webp", "gif"] where p.hasSuffix(e) { return "." + e }
                return ".jpg"
            }
            let picked = Array(sel).sorted()
            for (n, i) in picked.enumerated() {
                let u = hit.urls[i]
                guard let url = URL(string: u) else { failed += 1; continue }
                var req = URLRequest(url: url)
                req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                req.setValue(hit.page, forHTTPHeaderField: "Referer")
                do {
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if data.count > 3_000 { savedFiles.append((data, String(format: "%03d", n + 1) + ext(u))) }
                    else { failed += 1 }
                } catch { failed += 1 }
                done = n + 1
            }
            if dest == 1 {
                for (d, fn) in savedFiles {
                    let tmp = NSTemporaryDirectory() + "tl_" + fn
                    if (try? d.write(to: URL(fileURLWithPath: tmp))) != nil {
                        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
                            if st == .authorized || st == .limited {
                                PHPhotoLibrary.shared().performChanges {
                                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: URL(fileURLWithPath: tmp))
                                }
                            }
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)   // 给相册写入一点间隔
                    }
                }
            } else {
                let dir = SavePaths.seriesDir(base: "画廊", name: name)
                for (d, fn) in savedFiles {
                    try? d.write(to: dir.appendingPathComponent(fn))
                }
            }
            running = false
            BoxIsland.banner("百宝箱 · 图叻", savedFiles.isEmpty
                             ? "一张都没存下（可能被防盗链拦了）"
                             : "「\(String(name.prefix(20)))」已存 \(savedFiles.count) 张" + (failed > 0 ? "，失败 \(failed)" : ""))
            dismiss()
        }
    }
}

// MARK: - 藏·画廊：图集书架

struct GalleryHomeView: View {
    struct GAlbum: Identifiable {
        let id = UUID()
        let name: String
        let cover: URL?
        let files: [URL]
    }
    @State private var albums: [GAlbum] = []

    var body: some View {
        Group {
            if albums.isEmpty {
                ContentUnavailableView {
                    Label("画廊还空着", systemImage: "photo.stack")
                } description: {
                    Text("去 匣 › 内置浏览器，看到好图集\n点工具条上的 ✨ 一键聚图入库")
                } actions: {
                    NavigationLink("了解图叻计划") { GalleryAboutView() }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                              alignment: .leading, spacing: 12) {
                        ForEach(albums) { a in
                            NavigationLink {
                                GalleryPagerView(name: a.name, files: a.files)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    AsyncImage(url: a.cover) { ph in
                                        switch ph {
                                        case .success(let img): img.resizable().scaledToFill()
                                        default: Color.gray.opacity(0.1)
                                        }
                                    }
                                    .frame(height: 160).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(a.name).font(.subheadline).lineLimit(1)
                                    Text("\(a.files.count) 张").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除图集", role: .destructive) {
                                    if let first = a.files.first {
                                        try? FileManager.default.removeItem(
                                            at: first.deletingLastPathComponent())
                                    }
                                    load()
                                }
                            }
                        }
                    }.padding(12)
                }
            }
        }
        .navigationTitle("画廊 · \(albums.count)")
        .onAppear { load() }
        .refreshable { load() }
    }

    private func load() {
        let fm = FileManager.default
        let root = SavePaths.root("画廊")
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [GAlbum] = []
        for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["jpg", "jpeg", "png", "webp", "gif"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { continue }
            out.append(GAlbum(name: d.lastPathComponent, cover: files.first, files: files))
        }
        albums = out
    }
}

struct GalleryPagerView: View {
    let name: String
    let files: [URL]
    @State private var idx = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $idx) {
                ForEach(0..<files.count, id: \.self) { i in
                    AsyncImage(url: files[i]) { ph in
                        switch ph {
                        case .success(let img): img.resizable().scaledToFit()
                        case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                        default: ProgressView().tint(.white)
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            VStack {
                Spacer()
                Text("\(idx + 1) / \(files.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
