import SwiftUI
import Foundation

// MARK: - “已看完”标记（播放进度 ≥92% 时播放器自动标记）
enum WatchStore {
    private static let key = "watchedIDs"
    static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
    static func mark(_ id: String) {
        var s = all()
        guard !s.contains(id) else { return }
        s.insert(id)
        UserDefaults.standard.set(Array(s), forKey: key)
    }
    static func unmark(_ id: String) {
        var s = all(); s.remove(id)
        UserDefaults.standard.set(Array(s), forKey: key)
    }
    static func removeMany(_ ids: [String]) {
        var s = all()
        for i in ids { s.remove(i) }
        UserDefaults.standard.set(Array(s), forKey: key)
    }
}

// MARK: - 合集追更订阅
struct SubData: Codable, Identifiable, Hashable {
    let mixID: String
    let title: String
    var base: String = "短剧"      // 存放根：短剧 / 私密
    var lastTotal = 0              // 上次检测总集数
    var newCount = 0               // 待补的新集数
    var lastCheck = 0.0
    var id: String { mixID }
}

enum SubscriptionStore {
    private static let key = "mixSubsV1"
    static func all() -> [SubData] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SubData].self, from: d) else { return [] }
        return list
    }
    static func save(_ list: [SubData]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func exists(_ mixID: String) -> Bool { all().contains { $0.mixID == mixID } }
    static func add(mixID: String, title: String, base: String) {
        var list = all()
        guard !list.contains(where: { $0.mixID == mixID }) else { return }
        list.append(SubData(mixID: mixID, title: title, base: base))
        save(list)
    }
    static func remove(_ mixID: String) { save(all().filter { $0.mixID != mixID }) }
    static func update(_ s: SubData) {
        var list = all()
        if let i = list.firstIndex(where: { $0.mixID == s.mixID }) { list[i] = s; save(list) }
    }
    // 未收藏到本地的集（清单没有 或 文件缺失）
    static func pendings(_ mix: MixData) -> [MixEpisode] {
        let rec = MixManifest.map(mix.id)
        return mix.eps.filter { ep in
            if let rel = rec[ep.id], SavePaths.exists(rel: rel) { return false }
            return true
        }
    }
}

// MARK: - 订阅管理页
struct SubsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = BatchRunner()
    @State private var runningID: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.subs) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(s.title).font(.headline).lineLimit(2)
                            Spacer()
                            if s.newCount > 0 {
                                Text("有 \(s.newCount) 新集")
                                    .font(.caption2).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.green.opacity(0.9), in: Capsule())
                            }
                        }
                        Text(checkLine(s)).font(.caption).foregroundStyle(.secondary)
                        if runningID == s.mixID {
                            VStack(spacing: 4) {
                                ProgressView(value: Double(min(runner.got + runner.skipped + runner.failed, max(runner.total, 1))),
                                             total: Double(max(runner.total, 1)))
                                Text(runner.current.isEmpty ? "准备中…" : runner.current)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } else {
                            HStack(spacing: 16) {
                                Button {
                                    start(s)
                                } label: {
                                    Label("立即追更", systemImage: "cloud.down")
                                }
                                Button {
                                    Task { await app.checkOne(s) }
                                } label: {
                                    Label("检测", systemImage: "arrow.clockwise")
                                }
                                Button(role: .destructive) {
                                    SubscriptionStore.remove(s.mixID)
                                    app.loadSubs()
                                } label: {
                                    Label("退订", systemImage: "bell.slash")
                                }
                            }
                            .buttonStyle(.borderless).font(.callout)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if app.subs.isEmpty {
                    ContentUnavailableView("还没有订阅",
                                           systemImage: "bell",
                                           description: Text("解析合集链接 → 批量弹层里点「订阅此合集」\n以后打开 App 自动帮你发现新集"))
                }
            }
            .navigationTitle("合集订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.checkSubs() }
                    } label: {
                        if app.subsChecking { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(app.subsChecking)
                }
            }
        }
    }

    private func checkLine(_ s: SubData) -> String {
        var t = "共 \(s.lastTotal) 集 · 存到 \(s.base)"
        if s.lastCheck > 0 {
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm"
            t += " · 上次检测 " + df.string(from: Date(timeIntervalSince1970: s.lastCheck))
        } else {
            t += " · 还没检测过"
        }
        return t
    }

    private func start(_ s: SubData) {
        guard runningID == nil else { return }
        runningID = s.mixID
        Task { @MainActor in
            guard let mx = try? await MixAPI.fetch(mixID: s.mixID) else {
                runningID = nil
                return
            }
            await runner.start(mix: mx, base: s.base,
                               useEngine: EngineStore.current.isIfphp,
                               folderName: s.title) { }
            runningID = nil
            app.refresh(); app.refreshDramaSeries(); app.refreshPrivateSeries()
            await app.checkOne(s)
        }
    }
}
