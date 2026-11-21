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
    // v1.10.88 官方合集关系(归册金标准): 多季共用同一 relatedAlbumId, seasonIdx=官方季号;
    // albumFetched=档案已带官方结论(即便 albumId 空=单季), 免 backfill 反复重拉
    var albumId = ""
    var seasonIdx = 0
    var albumFetched = false
    // v1.10.89 档案身份证: sid + 官方真名 svrTitle(拉档那部剧的标题)。
    // backfill 曾把"搜不到同名就抓第一条"当兜底, 80集抖音版"云渺"被塞了云渺1的
    // 档案海报与季关系 — 从此只认同名命中, 并把真名存档供归册验明正身
    var sid = ""
    var svrTitle = ""
    /// v1.10.90 人工钦定"这是一部独立剧"(认档弹窗勾选): 归册时谁也不进
    var solo = false
    /// v1.10.116 手动合册钦定章: 用户点名和谁一个系列(存目标册号); 优先级仅次于 solo,
    /// 凌驾一切官方自动结论。117 教训重申=必须 Optional — 116 非可选默认值直接炸光全部旧档
    /// (synthesized Decodable 不为带初值的非可选属性合成缺键容错 110饿死案原样复发)
    var handAlbum: String?
    /// v1.10.110 自动验身复审戳: 验过不再占名额(真机案: 单剧 albumId 恒空致 need 名单死循环,
    /// 老千2 与行道者永远排不上队)。Optional = 合成 Codable 对缺键走 decodeIfPresent, 老档案不炸
    var reviewed: Bool?
    /// 红果侧查无同名(抖音版/下架)的结论标记: 归册见此标记不信 album, 且清掉假海报
    static let noMatch = "⊘无同名"
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
        // v1.10.90 重新认档/覆盖重拉时保住人工"钦定单剧"印章; v1.116 保住"手动合册"章
        m.solo = SeriesMetaStore.load(dir)?.solo ?? false
        m.handAlbum = SeriesMetaStore.load(dir)?.handAlbum
        m.total = s.episodeCount
        m.desc = s.description.trimmingCharacters(in: .whitespacesAndNewlines)
        m.heat = big(s.heat)
        m.plays = big(s.playCount)
        // v1.10.88 官方季关系入档(老档案缺此三字段=albumFetched false → 补档会重拉一次)
        m.albumId = s.relatedAlbumId
        m.seasonIdx = s.seasonIndex
        m.albumFetched = true
        // v1.10.89 身份证: 档案属于哪部官方剧写得明明白白
        m.sid = sid
        m.svrTitle = s.title
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
        var ok = 0, cleared = 0, skipped = 0
        for (i, s) in list.enumerated() {
            if Task.isCancelled { break }
            // v1.10.89 老档案没验过身份证(svrTitle 空)的会重拉一轮全库换证
            if let old = SeriesMetaStore.load(s.url), old.albumFetched, !old.svrTitle.isEmpty {
                skipped += 1
                continue
            }
            progress("验明正身 \(i + 1)/\(list.count)：\(s.name)")
            // v1.10.90 搜索口失败(限流/瞬抖)不写"查无"结论, 下次再来; 只有搜到了没同名才算无同名
            let r = try? await Hongguo.attempt(c, { try await c.search(s.name) })
            guard let pg = r else {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            // v1.10.106 同名比对抹空格标点(老千 2 文件夹带空格 官方名不带 一字不差卡死验身)
            if let hit = pg.items.first(where: { DramaShelf.norm($0.title) == DramaShelf.norm(s.name) }), !hit.id.isEmpty {
                await harvest(c, sid: hit.id, title: s.name, dir: s.url)
                if FileManager.default.fileExists(atPath: file(s.url).path) { ok += 1 }
                try? await Task.sleep(nanoseconds: 900_000_000)   // 匿名口温和
            } else {
                // 红果查无同名: 写死结论防反复白跑; 顺手卸掉可能攀错的 album 与假海报
                if var old = SeriesMetaStore.load(s.url) {
                    old.albumFetched = true
                    old.albumId = ""
                    old.seasonIdx = 0
                    old.svrTitle = SeriesMeta.noMatch
                    if old.cover {
                        try? FileManager.default.removeItem(at: s.url.appendingPathComponent("封面.jpg"))
                        old.cover = false
                    }
                    if let j = try? JSONEncoder().encode(old) { try? j.write(to: file(s.url)) }
                    cleared += 1
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        progress("补齐完成：新验 \(ok) 部 · 卸错档案 \(cleared) 部 · 已带证跳过 \(skipped) 部")
    }

    /// v1.10.116 手动并册落地: src 钦定与 other 同册; 册号优先沿用它俩已有的官方album,
    /// 都没有就自造私号(H+文件夹名) — 只影响本地分组, 不碰任何官方数据
    static func applyMerge(src: Series, into other: Series) {
        let m2 = load(other.url)
        let ha = m2?.handAlbum ?? ""
        let album: String = {
            if !ha.isEmpty { return ha }
            if let a = m2?.albumId, !a.isEmpty { return a }
            return "H" + other.url.lastPathComponent
        }()
        setHandAlbum(src.url, album)
        if m2?.albumId != album { setHandAlbum(other.url, album) }
        HGTrail.note("merge hand " + src.name + " into " + other.name + " A=" + album)
    }

    /// v1.10.116 手动合册盖章/拆章(album 传空=拆章回自动)
    static func setHandAlbum(_ dir: URL, _ album: String) {
        var m = SeriesMetaStore.load(dir) ?? SeriesMeta()
        m.handAlbum = album.isEmpty ? nil : album
        if let j = try? JSONEncoder().encode(m) { try? j.write(to: file(dir)) }
    }

    /// v1.10.110 复审盖章: 有档加戳, 无档立轻档(albumFetched+reviewed), 都不再占验身名额
    private static func stamp(_ dir: URL) {
        var m = SeriesMetaStore.load(dir) ?? SeriesMeta()
        m.albumFetched = true
        m.reviewed = true
        if let j = try? JSONEncoder().encode(m) { try? j.write(to: file(dir)) }
    }

    /// v1.10.111 合册大招: 官方认亲批量口 getSeriesBatch — 全库已建档 sid 一把集中核验,
    /// related 会事后补(老千2/剑二十四都是马后炮), 名字规则走不通的搜索通道从此双保险
    @MainActor
    static func reunion(_ list: [Series]) async -> Int {
        guard let c = Hongguo.client else { return 0 }
        var pairs: [(sid: String, dir: URL)] = []
        for s in list {
            guard let m = SeriesMetaStore.load(s.url), !m.sid.isEmpty, !m.solo else { continue }
            pairs.append((m.sid, s.url))
        }
        guard !pairs.isEmpty else { return 0 }
        var updated = 0, pos = 0
        var retry: [(sid: String, dir: URL)] = []
        while pos < pairs.count {
            if Task.isCancelled { break }
            let end = Swift.min(pos + 20, pairs.count)
            let chunk = Array(pairs[pos..<end])
            pos = end
            let r = try? await Hongguo.attempt(c, { try await c.getSeriesBatch(chunk.map { $0.sid }) })
            guard let ds = r else {
                HGTrail.note("reunion batch fail n=" + String(chunk.count))
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            for d in ds {
                guard let sd = d.series, !sd.id.isEmpty else { continue }
                for hit in chunk where hit.sid == sd.id {
                    guard var m = SeriesMetaStore.load(hit.dir) else { continue }
                    let before = m.albumId
                    // 只更新认亲三件套, 海报简介演员等存量不动
                    m.albumId = sd.relatedAlbumId
                    m.svrTitle = sd.title
                    m.albumFetched = true
                    m.reviewed = true
                    if let j = try? JSONEncoder().encode(m) { try? j.write(to: file(hit.dir)) }
                    if m.albumId != before {
                        updated += 1
                        HGTrail.note("reunion album sid=" + sd.id + " title=" + sd.title + " A=" + (m.albumId.isEmpty ? "单" : m.albumId))
                    } else if m.albumId.isEmpty {
                        // v1.10.112 批量口=缓存层, 官方新补的 related 会晚刷(111 真机实锤
                        // 老千2/剑二十四手机批量回空而 PC 单部口实时有) → 空户逐部单查补验
                        retry.append(hit)
                    }
                }
            }
            // v1.10.113 批量口还会整行失踪(112 遗嘱实锤: 老千2/剑二十四的 sid 请求了却没回行,
            // 连补验名单都进不去) → 没回行的也全部补进单查实检
            let got = Set(ds.compactMap { $0.series?.id })
            for hit in chunk where !got.contains(hit.sid) {
                HGTrail.note("reunion lost sid=" + hit.sid)
                retry.append(hit)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // v1.10.112 空户逐部走单部实时口补验(批量口是缓存层, 新补 related 会晚刷)
        for hit in retry {
            if Task.isCancelled { break }
            let one = try? await Hongguo.attempt(c, { try await c.getSeries(hit.sid) })
            if let one, !one.relatedAlbumId.isEmpty, var m = SeriesMetaStore.load(hit.dir) {
                m.albumId = one.relatedAlbumId
                m.svrTitle = one.title
                if let j = try? JSONEncoder().encode(m) { try? j.write(to: file(hit.dir)) }
                updated += 1
                HGTrail.note("reunion solo album sid=" + hit.sid + " title=" + one.title + " A=" + m.albumId)
            } else {
                HGTrail.note("reunion solo empty sid=" + hit.sid)
            }
            try? await Task.sleep(nanoseconds: 550_000_000)
        }
        HGTrail.note("reunion done n=" + String(pairs.count) + " retry=" + String(retry.count) + " changed=" + String(updated))
        return updated
    }

    /// v1.10.105 剧墙开门自动验明正身: 老千/老千2 案——官方 related 金标准一直有,
    /// 只是档案没拉到头上就不合册。开门补没档的, 温和限速, 搜不到先跳过不写死(留给手动按钮)
    @MainActor
    static func autoCheck(_ list: [Series]) async -> Int {
        guard let c = Hongguo.client else { return 0 }
        var need = list.filter { s in
            guard let old = SeriesMetaStore.load(s.url) else { return true }
            if old.solo { return false }
            if !old.albumFetched { return true }
            // v1.10.106 旧版 exact 误写的查无结论复审翻案
            if old.svrTitle == SeriesMeta.noMatch { return true }
            // v1.10.109 官方 related 会事后补(老千2 下当时空、今天复查已有) → 认证单剧也要复审
            // v1.10.110 但验过就打戳放行, 名额滚动给后来者(否则单剧空 albumId 无限占坑)
            return old.albumId.isEmpty && old.reviewed != true
        }
        need = Array(need.prefix(15))
        var ok = 0
        for s in need {
            if Task.isCancelled { break }
            let r = try? await Hongguo.attempt(c, { try await c.search(s.name) })
            guard let pg = r else {
                HGTrail.note("autocheck fail name=" + s.name + " (搜索口报错)")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            // v1.10.109 命中两阶梯: 先归一化全等; 再退"剥季号同基名"第一行
            // (真机病历: 文件夹"我家娘子不对劲第一季" 官方真名"我家娘子，不对劲" 一字之差永合不上)
            let nm = DramaShelf.norm(s.name)
            let bm = DramaShelf.norm(DramaShelf.base(s.name))
            var exact: Openhongguo.SeriesSummary?
            var baseHit: Openhongguo.SeriesSummary?
            for it in pg.items where !it.id.isEmpty {
                if DramaShelf.norm(it.title) == nm { exact = it; break }
                // v1.10.111 base 攀队加季号闸门: 只有名字带季号的才是续集宣言(老千2/娘子第一季),
                // 光杆"云渺"不许攀云渺家族(110 真机冤案: 官方 post-hoc related 把单剧拽进别人家册)
                if baseHit == nil, DramaShelf.seasonNo(s.name) > 0,
                   DramaShelf.norm(DramaShelf.base(it.title)) == bm { baseHit = it }
            }
            if let hit = exact ?? baseHit {
                HGTrail.note("autocheck hit name=" + s.name + " sid=" + hit.id + " mode=" + (exact == nil ? "base" : "exact"))
                await harvest(c, sid: hit.id, title: s.name, dir: s.url)
                if FileManager.default.fileExists(atPath: file(s.url).path) { ok += 1 }
            } else {
                let top = pg.items.prefix(3).map { $0.title }.joined(separator: " | ")
                HGTrail.note("autocheck miss name=" + s.name + " rows=\(pg.items.count) top=[" + top + "]")
            }
            // v1.10.110 无论命中与否, 验过即盖章; 无档 miss 的抖音独剧也立个轻档免年年白跑
            stamp(s.url)
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        HGTrail.note("shelf autocheck done=\(ok)/\(need.count)")
        return ok
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

    // v1.10.122 两轮马甲收割的去重合并: 同一条弹幕(t+x)只留一份
    private static func merge(_ num: Int, _ bag: [DMEntry],
                              _ all: inout [String: [DMEntry]], _ keys: inout [String: Set<String>]) {
        guard !bag.isEmpty else { return }
        let k = "\(num)"
        var set = keys[k] ?? []
        var add: [DMEntry] = []
        for e in bag {
            let key = "\(e.t)|\(e.x)"
            if set.contains(key) { continue }
            set.insert(key)
            add.append(e)
        }
        keys[k] = set
        if !add.isEmpty { all[k, default: []] += add }
    }

    @MainActor
    static func harvest(_ c: OpenhongguoClient, sid: String,
                        eps: [(num: Int, id: String)], dir: URL, maxRounds: Int = 8) async {
        var all: [String: [DMEntry]] = [:]
        var keys: [String: Set<String>] = [:]   // v1.10.122 去重账本 "集号"→{t|x}
        var anyPageOK = false          // 至少有一页成功才算"这剧真没弹幕", 防限流空手立假档
        // v1.10.122 换设备拼全量(SDK 源码实锤: 服务端按设备下发精选子集, 每台看到的不同;
        // 一集全量8093条, 单台匿名只分到35~297) — 第二轮前 resetDevice 换马甲再扫一遍,
        // 两轮并集去重, 弹幕量约翻倍; 代价每剧多 ~1 分钟后台
        // v1.10.123 每轮落一次盘: 并行收割中途被杀也保住已到手的部分, 不白干
        @discardableResult
        func dump(_ tag: String) -> Int {
            guard anyPageOK else {
                HGTrail.note("dm fail-all sid=\(sid) 未立档待重试")
                return -1
            }
            for k in all.keys where all[k]!.count > 1 { all[k] = all[k]!.sorted { $0.t < $1.t } }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if all.isEmpty {
                // 页页成功却条条皆空 = 这剧服务器真没弹幕: 立空档当"查过了"记号
                try? Data("{}".utf8).write(to: file(dir))
                HGTrail.note("dm empty sid=\(sid) 立空档")
                return 0
            }
            if let j = try? JSONEncoder().encode(all) {
                try? j.write(to: file(dir))
                HGTrail.note("dm ok(\(tag)) sid=\(sid) eps=\(all.count) bytes=\(j.count)")
                return j.count
            }
            return -1
        }
        // v1.10.124 马甲榨干制(用户"更多马甲"): 最多8轮换号连扫, 前3轮保底(单轮运气差不可杀,
        // 真机样本 r2 只涨0.7% r3 暴涨37%), 第3轮起连续两轮增量<4% 自动收手止损
        var lastBytes = -1
        var dryStreak = 0
        for rd in 1...max(1, maxRounds) {
            if rd > 1 { try? await c.resetDevice() }
            if rd > 1 { try? await Task.sleep(nanoseconds: 800_000_000) }   // 新号落地喘一口
            // 提速(用户投诉太慢): 每集页循环打包 6 集并发, 页间歇 60ms(PC 探针 40 连页无风控)
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
                            try? await Task.sleep(nanoseconds: 60_000_000)
                        } while cursor != nil
                        return (ep.num, bag.sorted { $0.t < $1.t }, ok)
                    }
                    inflight += 1
                    i += 1
                    if inflight >= 6 {
                        if let r = await grp.next() {
                            inflight -= 1
                            merge(r.0, r.1, &all, &keys)
                            if r.2 { anyPageOK = true }
                        }
                    }
                }
                for await r in grp {
                    if r.2 { anyPageOK = true }
                    merge(r.0, r.1, &all, &keys)
                }
            }
            let got = dump("r\(rd)")
            if rd >= 3, got >= 0, lastBytes > 0 {
                let gain = Double(got - lastBytes) / Double(max(lastBytes, 1))
                if gain < 0.04 { dryStreak += 1 } else { dryStreak = 0 }
                HGTrail.note("dm r\(rd) +\(got - lastBytes)B(\(Int(gain * 100))%) dry=\(dryStreak)")
                if dryStreak >= 2 {
                    HGTrail.note("dm 榨干收手 sid=\(sid) 共\(rd)轮")
                    break
                }
            }
            if got >= 0 { lastBytes = got }
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
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        progress("弹幕补齐：\(ok)/\(list.count) 部（后台继续加载坊即生效）")
    }
}

