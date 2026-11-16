import SwiftUI

// MARK: - 上帝视野·收割（worse_query 逃逸扫其他 App 容器的视频 → 入库）
// 内核只给"具体容器"开票不给父目录，所以：
//   路线A: 直接给 Data/Application 父目录开票（某些版本可）
//   路线B: pathleak 扫 inode 找出全部容器路径 → 逐个开票（结果缓存 7 天）
// AppGroup 区父目录可直接开票。只读+复制，绝不写删别人家文件。

struct WQHit: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int
    let source: String
}

@MainActor
final class WQHarvest: ObservableObject {
    @Published var lines: [String] = []
    @Published var hits: [WQHit] = []
    @Published var sel = Set<String>()
    @Published var scanning = false
    @Published var importing = false

    func scan(force: Bool = false) {
        guard !scanning else { return }
        scanning = true
        lines = []
        hits = []
        sel = []
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            guard let group = WQ.workingGroup() else {
                await MainActor.run { self.lines = ["✗ 没有组票（先跑探针确认签名带组）"]; self.scanning = false }
                return
            }
            var handles: [Int64] = []
            var found: [WQHit] = []
            var dirs: [(String, String)] = []   // (已开票目录, 标签)

            // 1) App 数据容器
            let dataRoot = "/var/mobile/Containers/Data/Application"
            if let r = WQ.escapeAny(dataRoot, group: group) {
                handles.append(r.handle)
                dirs.append((r.okPath, "影"))
                await MainActor.run { self.lines.append("✓ App数据 父目录直通") }
            } else {
                await MainActor.run { self.lines.append("App数据 父目录不给票 → 走 inode 普查（首次约十几秒，之后有缓存）") }
                let key = "wqContV3"
                var uuids: [String] = []
                let cache = UserDefaults.standard.dictionary(forKey: key) as? [String: Any]
                let stamp = (cache?["t"] as? TimeInterval) ?? 0
                if !force, Date().timeIntervalSince1970 - stamp < 7 * 86400, let arr = cache?["v"] as? [String] {
                    uuids = arr
                    await MainActor.run { self.lines.append("（用 7 天内缓存的 \(uuids.count) 个容器）") }
                } else {
                    let dl = Date().addingTimeInterval(70)
                    let (paths, diag, complete) = WQ.pathleak(dataRoot, deadline: dl)
                    uuids = paths
                    if complete {
                        UserDefaults.standard.set(["t": Date().timeIntervalSince1970, "v": paths], forKey: key)
                    }
                    await MainActor.run { self.lines.append("普查: \(diag) \(complete ? "已缓存" : "未扫完不缓存")") }
                }
                let cap = min(uuids.count, 160)
                var granted = 0
                await MainActor.run { self.lines.append("逐个开票 \(cap) 个…") }
                for p in uuids.prefix(cap) {
                    if Date() > t0.addingTimeInterval(90) { break }
                    if let r = WQ.escapeAny(p, group: group) {
                        handles.append(r.handle)
                        dirs.append((r.okPath, "影"))
                        granted += 1
                    }
                }
                await MainActor.run { self.lines.append("开票成功 \(granted)/\(cap)") }
            }

            // 2) AppGroup 共享区（父目录可直通）
            let agRoot = "/var/mobile/Containers/Shared/AppGroup"
            if let r = WQ.escapeAny(agRoot, group: group) {
                handles.append(r.handle)
                dirs.append((r.okPath, "组"))
                await MainActor.run { self.lines.append("✓ AppGroup 开通") }
            } else {
                await MainActor.run { self.lines.append("✗ AppGroup 开路失败") }
            }

            let deadline = t0.addingTimeInterval(120)
            for (root, lab) in dirs {
                found += WQWalk.walk(root, label: lab, deadline: deadline, budget: WQWalk.maxHits - found.count)
                if found.count >= WQWalk.maxHits { break }
            }
            handles.forEach { WQ.release($0) }
            let sorted = found.sorted { $0.size > $1.size }
            await MainActor.run {
                self.hits = sorted
                self.lines.append("=== \(String(format: "%.1f", Date().timeIntervalSince(t0)))s，\(sorted.count) 个视频（≥1.5MB，句柄已还）===")
                self.scanning = false
            }
        }
    }

    func importSel(app: AppState) {
        guard !importing, !sel.isEmpty else { return }
        importing = true
        let picked = hits.filter { sel.contains($0.id) }
        let jobs = TuoleiJobs.shared
        Task { @MainActor in
            app.keepAlive.start()
            let jid = jobs.add("上帝视野收割 \(picked.count) 条", total: picked.count)
            var done = 0, fails = 0, saved = 0
            for h in picked {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("wq_\(UUID().uuidString.prefix(8)).\(h.url.pathExtension.lowercased())")
                do {
                    try? FileManager.default.removeItem(at: out)
                    try FileManager.default.copyItem(at: h.url, to: out)
                    let stem = h.name.replacingOccurrences(of: "[^A-Za-z0-9一-龥._ -]", with: "_", options: .regularExpression)
                    let name = "WQ_\(h.source.split(separator: ":").last ?? "?")_\(String(stem.prefix(60)))"
                    if SavePaths.write(out, rel: name) {
                        DownloadStore.set(h.url.absoluteString, name)
                        saved += 1
                    } else { try? FileManager.default.removeItem(at: out); fails += 1 }
                } catch { fails += 1 }
                done += 1
                jobs.progress(jid, done, fails)
            }
            jobs.finish(jid)
            app.refresh()
            app.keepAlive.stop()
            self.importing = false
            BoxIsland.banner("百宝箱 · 上帝视野", "收割完成 \(saved) 条" + (fails > 0 ? "，失败 \(fails)" : ""))
            _ = done
        }
    }
}

// BFS 限深 4、跳过 Caches/tmp，撞 deadline 即停；非隔离，后台直跑
enum WQWalk {
    static let vexts: Set<String> = ["mp4", "mov", "m4v"]
    static let minSize = 1_500_000
    static let maxHits = 250

    static func walk(_ root: String, label: String, deadline: Date, budget: Int) -> [WQHit] {
        var out: [WQHit] = []
        let fm = FileManager.default
        var queue: [(String, Int)] = [(root, 0)]
        while let (dir, depth) = queue.popLast(), out.count < budget {
            if Date() > deadline { break }
            if depth > 0 {
                let bn = (dir as NSString).lastPathComponent
                if bn == "Caches" || bn == "tmp" || bn == "SystemData" { continue }
            }
            guard let subs = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for s in subs {
                let full = dir + "/" + s
                var st = stat()
                if lstat(full, &st) != 0 { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                if isDir {
                    if depth < 4 { queue.append((full, depth + 1)) }
                } else {
                    let ext = (s as NSString).pathExtension.lowercased()
                    if vexts.contains(ext) && st.st_size >= minSize {
                        let src = label + ":" + ((root as NSString).lastPathComponent.prefix(8)).description
                        out.append(WQHit(url: URL(fileURLWithPath: full), name: s, size: Int(st.st_size), source: src))
                        if out.count >= budget { break }
                    }
                }
            }
        }
        return out
    }
}

struct WQHarvestView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var hq = WQHarvest()

    var body: some View {
        List {
            Section {
                HStack {
                    Button(hq.scanning ? "扫描中…" : "扫描全部容器视频") { hq.scan() }
                        .disabled(hq.scanning || hq.importing)
                    Spacer()
                    Button("重扫inode") { hq.scan(force: true) }
                        .font(.callout).disabled(hq.scanning || hq.importing)
                }
                ForEach(Array(hq.lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(.caption, design: .monospaced))
                }
                if hq.importing {
                    HStack { ProgressView().controlSize(.small); Text("导入中…").font(.caption) }
                }
            }
            if !hq.hits.isEmpty {
                Section {
                    HStack {
                        Text("\(hq.hits.count) 条 · 已选 \(hq.sel.count)")
                        Spacer()
                        Button("全选") { hq.sel = Set(hq.hits.map(\.id)) }.font(.callout)
                        Button("全不选") { hq.sel = [] }.font(.callout)
                        Button {
                            hq.importSel(app: app)
                        } label: { Text("导入⬇").foregroundStyle(.orange) }
                        .disabled(hq.sel.isEmpty || hq.importing)
                    }
                }
                ForEach(hq.hits) { it in
                    HStack(spacing: 10) {
                        Button {
                            if hq.sel.contains(it.id) { hq.sel.remove(it.id) } else { hq.sel.insert(it.id) }
                        } label: {
                            Image(systemName: hq.sel.contains(it.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(hq.sel.contains(it.id) ? Color.orange : .secondary)
                        }
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.name).font(.subheadline).lineLimit(2)
                            Text("\(it.source) · \(Bytef.pretty(it.size))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "film").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("上帝视野收割")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { if hq.lines.isEmpty { hq.scan() } }
    }
}

enum Bytef {
    static func pretty(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2f GB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1f MB", Double(n) / 1e6) }
        return "\(n / 1024) KB"
    }
}
