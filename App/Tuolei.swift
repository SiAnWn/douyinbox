import SwiftUI
import Photos

// MARK: - 图叻：网页聚图引擎 v1（通吃模式：懒加载滚动 → DOM 全量聚图 → 预览勾选 → 批量入库）

struct TuoleiHit: Identifiable {
    let id = UUID()
    let title: String
    let urls: [String]
    let ws: [Int]
    let hs: [Int]
    let page: String
}

enum TuoleiJS {
    // v3：原图溯源（data 属性 → srcset 最大档 → 包裹链接 href）+ 广告容器识别 + 尺寸上报
    static let collect = """
    (() => {
      (async () => {
        for (let i = 0; i < 24; i++) {
          window.scrollBy(0, innerHeight * 0.9);
          await new Promise(r => setTimeout(r, 280));
          if ((window.innerHeight + window.scrollY) >= document.body.scrollHeight - 12) break;
        }
        window.scrollTo(0, 0);
        await new Promise(r => setTimeout(r, 250));
        const pick = im => {
          const d = im.dataset || {};
          for (const k of ['src','original','lazySrc','lazy-src','actualsrc','actual-src','origin','big','full','zoom','imgurl','img']) {
            const v = d[k];
            if (v && /^https?:\\/\\//.test(v)) return v;
          }
          const ss = im.getAttribute('srcset');
          let best = 0, cand = null;
          if (ss) for (const p of ss.split(',')) {
            const t = p.trim().split(/\\s+/);
            const n = parseInt(t[1]) || 0;
            if (n > best) { best = n; cand = t[0]; }
          }
          if (cand && /^https?:|^\\//.test(cand)) return cand;
          const a = im.closest && im.closest('a[href]');
          if (a && /\\.(jpe?g|png|webp)([?#]|$)/i.test(a.getAttribute('href') || '')) return a.href;
          return im.currentSrc || im.src || '';
        };
        const adish = im => {
          let e = im, up = 0;
          while (e && up < 4) {
            const c = ((e.className || '') + ' ' + (e.id || '')).trim();
            if (/(^|[\\s_.-])(ad|ads|advert|sponsor|banner|pop)([\\s_.-]|$)/i.test(c)) return true;
            e = e.parentElement; up++;
          }
          return false;
        };
        const seen = new Set(); const urls = [], ws = [], hs = [];
        const push = (s, w, h) => {
          try { s = new URL(s, location.href).href.split('#')[0]; } catch (e) { return; }
          if (!/^https?:/i.test(s) || s.startsWith('data:') || seen.has(s)) return;
          seen.add(s); urls.push(s); ws.push(w | 0); hs.push(h | 0);
        };
        for (const im of document.images) {
          if (adish(im)) continue;
          const s = pick(im);
          if (!s || String(s).startsWith('data:')) continue;
          push(s, im.naturalWidth || im.width || 0, im.naturalHeight || im.height || 0);
        }
        for (const a of document.links) {
          const h0 = (a.href || '').split('#')[0];
          if (/\\.(jpe?g|png|webp|gif)(\\?|$)/i.test(h0)) push(h0, 0, 0);
        }
        const og = document.querySelector('meta[property="og:image"], meta[name="og:image"]');
        if (og && og.content) push(og.content, 0, 0);
        window.webkit.messageHandlers.boxtuolei.postMessage(JSON.stringify({
          t: (document.title || location.hostname).trim(), u: urls, w: ws, h: hs, page: location.href
        }));
      })();
      return 'go';
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
    @State private var minSide = 300      // 尺寸筛选（长边像素下限，未知尺寸放行）
    @State private var running = false
    @State private var done = 0
    @State private var failed = 0

    private var rows: [Int] {
        hit.urls.indices.filter { i in
            minSide == 0 || hit.ws[i] == 0 || max(hit.ws[i], hit.hs[i]) >= minSide
        }
    }

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
                    Text("\(sel.count)/\(rows.count)")
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }.padding([.horizontal, .top], 14)

                HStack(spacing: 10) {
                    Picker("", selection: $dest) {
                        Text("存画廊").tag(0)
                        Text("存系统相册").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Picker("", selection: $minSide) {
                        Text("不限").tag(0)
                        Text("≥300").tag(300)
                        Text("≥600").tag(600)
                        Text("≥900").tag(900)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: 190)
                }
                .padding(.horizontal, 14).padding(.top, 12)

                ScrollView {
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(rows, id: \.self) { i in
                            AsyncImage(url: URL(string: hit.urls[i])) { ph in
                                switch ph {
                                case .success(let img): img.resizable().scaledToFill()
                                case .failure: Color.gray.opacity(0.15)
                                default: Color.gray.opacity(0.08)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 108)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(sel.contains(i) ? Color.accentColor.opacity(0.20) : Color.clear)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: sel.contains(i) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(sel.contains(i) ? Color.white : Color.white.opacity(0.9))
                                    .background(Circle().fill(sel.contains(i) ? Color.accentColor : Color.black.opacity(0.4)))
                                    .padding(6)
                            }
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(sel.contains(i) ? Color.accentColor : Color.black.opacity(0.22),
                                              lineWidth: sel.contains(i) ? 3 : 1))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture {
                                if sel.contains(i) { sel.remove(i) } else { sel.insert(i) }
                            }
                        }
                    }.padding(.horizontal, 10)
                }

                HStack(spacing: 14) {
                    Button("全选") { sel = Set(rows) }
                    Button("全不选") { sel = [] }
                    Button("反选") {
                        var s = Set<Int>()
                        for i in rows where !sel.contains(i) { s.insert(i) }
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
            .navigationTitle("图叻 · 聚到 \(rows.count) 张")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { sel = Set(rows) }
            .onChange(of: minSide) { _, _ in sel = Set(rows) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(running ? "后台下载" : "取消") { dismiss() }
                }
            }
        }
    }

    private func run() {
        running = true
        app.keepAlive.start()      // 退出选图页/切后台也不掐下载
        Task { @MainActor in
            defer { app.keepAlive.stop() }
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
                                GalleryAlbumView(name: a.name, files: a.files)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    AsyncImage(url: a.cover) { ph in
                                        switch ph {
                                        case .success(let img): img.resizable().scaledToFill()
                                        default: Color.gray.opacity(0.1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
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

// 图集内所有图的网格（点某张 → 大图；右上▶ 全图集幻灯片）
struct GalleryAlbumView: View {
    let name: String
    let files: [URL]
    @AppStorage("slideshowInterval") private var slideSec = 3
    @State private var playStart: Int?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(0..<files.count, id: \.self) { i in
                    NavigationLink {
                        GalleryPagerView(name: name, files: files, start: i)
                    } label: {
                        AsyncImage(url: files[i]) { ph in
                            switch ph {
                            case .success(let img): img.resizable().scaledToFill()
                            case .failure: Color.gray.opacity(0.15)
                            default: Color.gray.opacity(0.08)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 130)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            Text("\(i + 1)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                                .padding(4)
                                .background(Capsule().fill(.black.opacity(0.45)))
                                .padding(5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }.padding(10)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if slideSec == 0 { slideSec = 3 }
                    playStart = 0
                } label: { Image(systemName: "play.rectangle") }
            }
        }
        .navigationDestination(item: $playStart) { s in
            GalleryPagerView(name: name, files: files, start: s)
        }
    }
}

// 大图 + 幻灯片（速度菜单：手动/1/2/3/4 秒，选择记忆）
struct GalleryPagerView: View {
    let name: String
    let files: [URL]
    @AppStorage("slideshowInterval") private var slideSec = 3
    @State private var idx: Int

    init(name: String, files: [URL], start: Int = 0) {
        self.name = name
        self.files = files
        _idx = State(initialValue: max(0, min(start, max(0, files.count - 1))))
    }

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
                HStack(spacing: 10) {
                    Text("\(idx + 1) / \(files.count)")
                        .font(.caption.monospacedDigit())
                    if slideSec > 0 {
                        Label("\(slideSec)s", systemImage: "play.circle")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.bottom, 12)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("手动翻页") { slideSec = 0 }
                    Divider()
                    ForEach([1, 2, 3, 4], id: \.self) { s in
                        Button {
                            slideSec = s
                        } label: {
                            HStack { Text("\(s) 秒/张"); if slideSec == s { Image(systemName: "checkmark") } }
                        }
                    }
                } label: { Image(systemName: "slider.horizontal.below.rectangle") }
            }
        }
        .task(id: slideSec) {
            guard slideSec > 0, files.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(slideSec) * 1_000_000_000)
                if Task.isCancelled { break }
                withAnimation { idx = (idx + 1) % files.count }
            }
        }
    }
}
