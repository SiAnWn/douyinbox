import Foundation
import Openhongguo

// MARK: - 剧档案（v1.10.11）: GetSeries 的信息行(季/分类/演员/评分)自动入库
// 上游 SDK v0.3.1 起 Series.rows = 详情页 secondary_infos(演员行 kind33 "演员·A B"、评分 kind4…)。
// 整剧下载完成自动 harvest 一份存 <剧文件夹>/剧信息.json; 坊底条与补档按钮读它。零额外轮次(一部一次 getSeries)。

struct SeriesMeta: Codable {
    var title = ""
    var castRow = ""      // "演员·A B"
    var scoreRow = ""     // 评分行原文
    var catRow = ""       // 分类行
    var seasonRow = ""    // 季行
    var tagRow = ""       // 标签行
    var heat = ""
    var plays = ""
    var total = 0
    var fetchedAt = ""
}

enum SeriesMetaStore {
    static func file(_ dir: URL) -> URL { dir.appendingPathComponent("剧信息.json") }

    static func load(_ dir: URL) -> SeriesMeta? {
        guard let d = try? Data(contentsOf: file(dir)) else { return nil }
        return try? JSONDecoder().decode(SeriesMeta.self, from: d)
    }

    /// 坊底条副行: 演员·… · 9.1分 (有什么显什么, 没档案返回空)
    static func line(_ m: SeriesMeta?) -> String {
        guard let m else { return "" }
        var parts: [String] = []
        if !m.castRow.isEmpty { parts.append(m.castRow) }
        if !m.scoreRow.isEmpty { parts.append(m.scoreRow) }
        if !m.catRow.isEmpty { parts.append(m.catRow) }
        return parts.joined(separator: " · ")
    }

    private static func big(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 1e8) }
        if n >= 10_000 { return "\(n / 10_000)万" }
        return n > 0 ? "\(n)" : ""
    }

    static func harvest(_ c: OpenhongguoClient, sid: String, title: String, dir: URL) async {
        guard let s = try? await Hongguo.attempt(c, { try await c.getSeries(sid) }) else {
            HongguoTrail.log("meta fail sid=\(sid)")
            return
        }
        var m = SeriesMeta()
        m.title = title
        m.total = s.episodeCount
        m.heat = big(s.heat)
        m.plays = big(s.playCount)
        for r in s.rows {
            let t = r.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if r.kind == InfoKind.twoActors { m.castRow = t }
            else if r.kind == InfoKind.score { m.scoreRow = t }
            else if r.kind == InfoKind.category { m.catRow = t }
            else if r.kind == InfoKind.seasonOrder { m.seasonRow = t }
            else if r.kind == InfoKind.tags { m.tagRow = t }
        }
        m.fetchedAt = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let j = try? JSONEncoder().encode(m) { try? j.write(to: file(dir)) }
        HongguoTrail.log("meta ok sid=\(sid) cast=\(m.castRow.isEmpty ? "-" : "y") score=\(m.scoreRow)")
    }

    /// 印页补档: 已下旧剧按文件夹名 search 命中同名剧 → harvest 写档案
    @MainActor
    static func backfill(_ app: AppState, progress: @escaping (String) -> Void) async {
        guard let c = Hongguo.client else { progress("红果引擎未就绪"); return }
        let list = app.dramaSeries
        guard !list.isEmpty else { progress("剧库是空的"); return }
        var ok = 0
        for (i, s) in list.enumerated() {
            if Task.isCancelled { break }
            progress("补齐中 \(i + 1)/\(list.count)：\(s.name)")
            guard let pg = try? await Hongguo.attempt(c, { try await c.search(s.name) }),
                  !pg.items.isEmpty else { continue }
            let hit = pg.items.first { $0.title == s.name } ?? pg.items.first
            guard let sid = hit?.id, !sid.isEmpty else { continue }
            await harvest(c, sid: sid, title: s.name, dir: s.url)
            if FileManager.default.fileExists(atPath: file(s.url).path) { ok += 1 }
            try? await Task.sleep(nanoseconds: 900_000_000)   // 匿名口温和
        }
        progress("补齐完成：\(ok)/\(list.count) 部落了档案")
    }
}
