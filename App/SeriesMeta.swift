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
    var desc = ""
    var cover = false
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
            HGTrail.note("meta fail sid=\(sid)")
            return
        }
        var m = SeriesMeta()
        m.title = title
        m.total = s.episodeCount
        m.desc = s.description.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // 官方海报当场落盘(签名链接会过期, 存成 封面.jpg 才永固; 卡面选取已优先它)
        if !s.coverUrl.isEmpty, let cu = URL(string: s.coverUrl),
           let (cd, _) = try? await URLSession.shared.data(from: cu), cd.count > 3_000 {
            try? cd.write(to: dir.appendingPathComponent("封面.jpg"))
            m.cover = true
        }
        if let j = try? JSONEncoder().encode(m) { try? j.write(to: file(dir)) }
        HGTrail.note("meta ok sid=\(sid) cast=\(m.castRow.isEmpty ? "-" : "y") cover=\(m.cover)")
    }

    /// 印页补档: 已下旧剧按文件夹名 search 命中同名剧 → harvest 写档案
    @MainActor
    static func backfill(_ app: AppState, progress: @escaping (String) -> Void) async {
        guard let c = Hongguo.client else { progress("红果引擎未就绪"); return }
        let list = app.dramaSeries
        guard !list.isEmpty else { progress("剧库是空的"); return }
        var ok = 0, skipped = 0
        for (i, s) in list.enumerated() {
            if Task.isCancelled { break }
            // 增量补档: 已有简介或海报=档案有效, 直接跳过(一千部剧只补那缺的一部)
            if let old = SeriesMetaStore.load(s.url), !old.desc.isEmpty || old.cover {
                skipped += 1
                continue
            }
            progress("补齐中 \(i + 1)/\(list.count)：\(s.name)")
            guard let pg = try? await Hongguo.attempt(c, { try await c.search(s.name) }),
                  !pg.items.isEmpty else { continue }
            let hit = pg.items.first { $0.title == s.name } ?? pg.items.first
            guard let sid = hit?.id, !sid.isEmpty else { continue }
            await harvest(c, sid: sid, title: s.name, dir: s.url)
            if FileManager.default.fileExists(atPath: file(s.url).path) { ok += 1 }
            try? await Task.sleep(nanoseconds: 900_000_000)   // 匿名口温和
        }
        progress("补齐完成：新补 \(ok) 部 · 已有档案跳过 \(skipped) 部")
    }
}

// 离线弹幕仓库(v1.10.14): 短剧/<剧>/弹幕.json = {"集号":[{t毫秒,x文本}...]}
// 领档案后由 hongguoRun / 补弹幕按钮顺手全量拉取(分页游标, 精选档, 落盘后播放零流量)。
struct DMEntry: Codable { var t: Int; var x: String }

enum DanmakuStore {
    static func file(_ dir: URL) -> URL { dir.appendingPathComponent("弹幕.json") }

    static func loadEps(_ dir: URL) -> [Int: [DMItem]]? {
        guard let d = try? Data(contentsOf: file(dir)),
              let j = try? JSONDecoder().decode([String: [DMEntry]].self, from: d) else { return nil }
        var out: [Int: [DMItem]] = [:]
        for (k, arr) in j {
            guard let n = Int(k) else { continue }
            out[n] = arr.map { DMItem(t: $0.t, x: $0.x) }
        }
        return out
    }

    @MainActor
    static func harvest(_ c: OpenhongguoClient, sid: String,
                        eps: [(num: Int, id: String)], dir: URL) async {
        var all: [String: [DMEntry]] = [:]
        var anyPageOK = false          // 至少有一页成功才算"这剧真没弹幕", 防限流空手立假档
        // 提速(用户投诉太慢): 每集页循环打包 3 集一组并发, 页间歇 250→120ms(PC 探针 40 连页 200ms 实测无风控)
        await withTaskGroup(of: (Int, [DMEntry], Bool).self) { grp in
            var i = 0
            var inflight = 0
            while i < eps.count {
                if Task.isCancelled { break }
                let ep = eps[i]
                grp.addTask {
                    var bag: [DMEntry] = []
                    var ok = false
                    var cursor: String?
                    var hops = 0
                    repeat {
                        hops += 1
                        guard hops < 30 else { break }                   // 单集最多 30 页保险丝
                        let pg = try? await Hongguo.attempt(c, {
                            try await c.listDanmaku(sid, episodeId: ep.id,
                                                    options: DanmakuOptions(cursor: cursor))
                        })
                        guard let pg else { break }
                        ok = true
                        bag += pg.items.map { DMEntry(t: $0.offsetMs, x: $0.text) }
                        cursor = pg.hasMore ? pg.cursor : nil
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    } while cursor != nil
                    return (ep.num, bag.sorted { $0.t < $1.t }, ok)
                }
                inflight += 1
                i += 1
                if inflight >= 3 {
                    if let r = await grp.next() {
                        inflight -= 1
                        if r.2 { anyPageOK = true }
                        if !r.1.isEmpty { all["\(r.0)"] = r.1 }
                    }
                }
            }
            for await r in grp {
                if r.2 { anyPageOK = true }
                if !r.1.isEmpty { all["\(r.0)"] = r.1 }
            }
        }
        guard anyPageOK else {
            // 一页都没成功(注册口限流/网络抖动): 不立档不留假证据, 下次补档按钮会再战
            HGTrail.note("dm fail-all sid=\(sid) 未立档待重试")
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if all.isEmpty {
            // 页页成功却条条皆空 = 这剧服务器真没弹幕: 立空档当"查过了"记号
            try? Data("{}".utf8).write(to: file(dir))
            HGTrail.note("dm empty sid=\(sid) 立空档")
            return
        }
        if let j = try? JSONEncoder().encode(all) {
            try? j.write(to: file(dir))
            HGTrail.note("dm ok sid=\(sid) eps=\(all.count) bytes=\(j.count)")
        }
    }

    /// 印页专用: 给已入库旧剧按剧名补弹幕(跳过已有档案的)
    @MainActor
    static func backfill(_ app: AppState, progress: @escaping (String) -> Void) async {
        guard let c = Hongguo.client else { progress("红果引擎未就绪"); return }
        let all = app.dramaSeries
        let list = all.filter { !FileManager.default.fileExists(atPath: file($0.url).path) }
        guard !list.isEmpty else { progress("弹幕档案都已齐（\(all.count) 部）"); return }
        var ok = 0
        for (i, s) in list.enumerated() {
            progress("拉弹幕 \(i + 1)/\(list.count)：\(s.name)")
            guard let pg = try? await Hongguo.attempt(c, { try await c.search(s.name) }),
                  let hit = pg.items.first(where: { $0.title == s.name }) ?? pg.items.first,
                  !hit.id.isEmpty else { continue }
            guard let page = try? await Hongguo.attempt(c, { try await c.listEpisodes(hit.id) }) else { continue }
            let pairs = page.items.filter { $0.playable }
                .map { (num: $0.number > 0 ? $0.number : 0, id: $0.id) }
                .filter { $0.num > 0 }
            await harvest(c, sid: hit.id, eps: pairs, dir: s.url)
            if FileManager.default.fileExists(atPath: file(s.url).path) { ok += 1 }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        progress("弹幕补齐：\(ok)/\(list.count) 部（后台继续加载坊即生效）")
    }
}

