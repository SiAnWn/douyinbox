import SwiftUI
import Openhongguo

// MARK: - 红果剧场 v2（v1.10.24 A菜二期）: 藏→"场" = 发现·榜单·上新·分类 四段
// 全部匿名目录接口(播放闸从未波及): shortRank 榜单(内容×榜单两级)/ newReleases 上新日历/
// shortFilterPanel+shortFilter 官方筛选墙/ hotSearch 热搜猜词 / discover+search 老两样。
// 一切剧行 → HgWant → 详情 → 一键整剧下载(送回拾页发车)。接口签名 11-18 PC 探针实锤。

struct HgWant: Hashable {
    let sid: String
    let title: String
    var eps: [Int] = []        // v1.10.36 选集直发: 只下这些集(空=整剧)
}

// 演员导航两式: 榜上已有 uid 直落 / 简介页只有名字先查人气榜补 uid
struct HgActorGo: Hashable {
    let uid: String
    let name: String
}
struct HgActor: Hashable {
    let name: String
}

// 封面银行(v1.10.30): 搜索接口经常不给封面(PC 探针实锤 3/4 为空),
// 但首页/榜单/上新见过的封面全在这里存着, 按剧号回填 = 搜索结果也有图
enum CoverBank {
    static var data: [String: String] = [:]

    static func put(_ sid: String, _ cover: String) {
        if !sid.isEmpty && !cover.isEmpty && data[sid] == nil { data[sid] = cover }
    }
    static func register(_ items: [SeriesSummary]) {
        for s in items { put(s.id, s.coverUrl) }
    }
    static func registerRank(_ items: [RankItem]) {
        for it in items { put(it.seriesId, it.coverUrl) }
    }
    static func registerNew(_ items: [NewRelease]) {
        for n in items { put(n.seriesId, n.coverUrl) }
    }
    static func registerWorks(_ items: [Work]) {
        for w in items { put(w.seriesId, w.coverUrl) }
    }
}

// 红果演员头像发的是 http:// 明文链(App 内不挑, 咱 iOS ATS 一律枪毙明文 HTTPS 请求),
// 头像全灰的真凶=v.60; PC 实测同款 https 200 可达(heic 小图 UIImage 原生能解).
// 所有异步图 URL 出门前先过这道拆弹.
func hgImgURL(_ s: String) -> String {
    if s.hasPrefix("http://") { return "https://" + s.dropFirst(7) }
    return s
}

func hgCoverUrl(sid: String, _ url: String) -> String {
    if !url.isEmpty { return hgImgURL(url) }
    return hgImgURL(CoverBank.data[sid] ?? "")
}

// 程序化导航(v1.10.34 根治闪屏): NavigationLink 的推屏动画会被列表
// 异步刷新(封面回填等)中途打断, 界面卡在旧页而栈里已压了新页,
// 返回时"又弹详情". Button+path.append 不吃动画状态, 列表怎么抖都稳.
//
// v1.10.38 感叹号顽案照抄 iDuanJu 实战答案(用户钦定抄码, GPL 私人侧载无碍):
// ①单一 Route 枚举走全栈跳转 + 一份注册钉在根内容(他们的 routes() 真机天天验证)
// ②path 归视图自己 @State 持有(他们 RootTabView 同款), TheaterNav 只拿 bind,
//   不再让 NavigationPath 住 @Published —— 少一层间接, 解析更实在
@MainActor
final class TheaterNav: ObservableObject {
    static let shared = TheaterNav()
    private init() {}

    enum Route: Hashable {
        case want(HgWant)
        case actorGo(HgActorGo)
        case actor(HgActor)
        case search          // v1.10.41: 搜索页也走值跳转(iDuanJu Route.search 同款),
                             // 全栈只留一种推屏姿势, 治"侧滑返回跳过搜索页直落主页"
    }

    var bind: Binding<NavigationPath>?

    private func push(_ r: Route, _ tag: String) {
        HGTrail.note("hg nav push " + (tag.isEmpty ? "?" : tag) + " depth=" + String(bind?.wrappedValue.count ?? -1))
        guard let b = bind else {
            HGTrail.note("hg nav UNBOUND")
            return
        }
        b.wrappedValue.append(r)
    }

    func go(_ w: HgWant, _ tag: String = "") { push(.want(w), tag) }
    func go(_ a: HgActorGo, _ tag: String = "") { push(.actorGo(a), tag) }
    func go(_ a: HgActor, _ tag: String = "") { push(.actor(a), tag) }
    func openSearch(_ tag: String = "") { push(.search, tag) }

    func back() {
        guard let b = bind, b.wrappedValue.count > 0 else { return }
        HGTrail.note("hg nav pop to \(b.wrappedValue.count - 1)")
        b.wrappedValue.removeLast()
    }

    func toRoot() {
        HGTrail.note("hg nav toRoot")
        bind?.wrappedValue = NavigationPath()
    }
}

// MARK: - 精装组件(v1.10.28 抄开心果/红果作业四件套, 适配盒子)

// 热度写法跟红果一致: 4165万 / 1.2亿
func hgWan(_ n: Int) -> String {
    if n >= 100_000_000 {
        var s = String(format: "%.1f", Double(n) / 1e8)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s + "亿"
    }
    if n >= 10_000 { return "\(n / 10_000)万" }
    return "\(n)"
}

// 上新日历的人话: 今天/明天/昨天/M月D日
func hgDay(_ d: String, today: String) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd"
    guard let dd = f.date(from: d), let tt = f.date(from: today),
          let n = Calendar(identifier: .gregorian).dateComponents([.day], from: tt, to: dd).day else {
        return d
    }
    switch n {
    case 0: return "今天"
    case 1: return "明天"
    case -1: return "昨天"
    default:
        let c = Calendar(identifier: .gregorian).dateComponents([.month, .day], from: dd)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}

// 榜单涨跌角标: 新上榜橙NEW / 升红↑ / 降绿↓ / 不变隐身
func hgArrow(_ ch: RankChange?) -> (String, Color)? {
    guard let ch else { return nil }
    switch ch.kind.rawValue {
    case 0: return ("新", Color.orange)
    case 1: return ("↑" + (ch.places > 0 ? "\(ch.places)" : ""), Color.red)
    case 2: return ("↓" + (ch.places > 0 ? "\(ch.places)" : ""), Color.green)
    default: return nil
    }
}

// 前三名金银铜奖牌徽章(开心果同款气质, 颜色自调)
struct RankBadge2: View {
    let rank: Int
    var body: some View {
        let colors = [Color(red: 0.95, green: 0.68, blue: 0.13),
                      Color(white: 0.62),
                      Color(red: 0.76, green: 0.47, blue: 0.27)]
        Text("\(rank)")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(rank <= 3 ? colors[rank - 1] : Color.black.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// 海报底座: 固定比例+封面 overlay+细描边(v1.9.50 铁律的完全体)
struct Poster2: View {
    let url: String
    var radius: CGFloat = 10
    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: url)) { $0.resizable().scaledToFill() }
                    placeholder: { Color.gray.opacity(0.16) }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

// 首屏骨架: 加载不再干转圈(灰海报格子等人)
struct GridSkeleton: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                  spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                Color.gray.opacity(0.14)
                    .aspectRatio(0.7, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

// 横滑卡栏(首页 rails 与上新预告共用)
struct HRail: View {
    @EnvironmentObject private var nav: TheaterNav
    let title: String
    let sub: String?
    let items: [CardLike]
    var circle = false

    struct CardLike: Hashable {
        let sid: String
        let title: String
        let sub: String
        let cover: String
        let rank: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 16, weight: .heavy))
                if let s = sub, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                        Button { nav.go(HgWant(sid: c.sid, title: c.title), "rail " + c.sid) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Poster2(url: hgCoverUrl(sid: c.sid, c.cover))
                                    .overlay(alignment: .topLeading) {
                                        if c.rank > 0 {
                                            RankBadge2(rank: c.rank).padding(5)
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        if !c.sub.isEmpty {
                                            Text(c.sub)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(Color.black.opacity(0.5), in: Capsule())
                                                .padding(5)
                                        }
                                    }
                                Text(c.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .frame(width: 104, alignment: .leading)
                            }
                            .frame(width: 104)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// 首页三条横滑榜的数据(热播/新剧/必看, 全部现成匿名榜单口)
@MainActor
final class RailVM: ObservableObject {
    @Published var hot: [HRail.CardLike] = []
    @Published var fresh: [HRail.CardLike] = []
    @Published var must: [HRail.CardLike] = []
    private var loaded = false

    func load() {
        guard !loaded else { return }
        loaded = true
        Task {
            guard let c = Hongguo.client else { return }
            let boards: [(String, (RailVM, [HRail.CardLike]) -> Void)] = [
                ("ranklist_hot_play_sc", { $0.hot = $1 }),
                ("ranklist_new_rank_sc", { $0.fresh = $1 }),
                ("ranklist_must_watch", { $0.must = $1 }),
            ]
            for (board, set) in boards {
                // v1.10.57 顺游标凑 20 条: 单页 shortRank 只回 ~10, 搜索页 TOP 区
                // 要 4-20 的续料(首页滑轨用不满不打紧)
                var out: [HRail.CardLike] = []
                var cursor: String?
                for _ in 0..<3 {
                    let sr = try? await Hongguo.attempt(c, {
                        try await c.shortRank(ShortRankQuery(board: board, cursor: cursor))
                    })
                    guard let sr else { break }
                    CoverBank.registerRank(sr.items)   // 每页都入银行供缺图兜底
                    for it in sr.items where !it.seriesId.isEmpty {
                        out.append(HRail.CardLike(sid: it.seriesId, title: it.title,
                                                  sub: it.score, cover: it.coverUrl, rank: it.position))
                    }
                    cursor = (sr.hasMore && out.count < 20) ? sr.cursor : nil
                    if cursor == nil { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                set(self, Array(out.prefix(20)))
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }
}

enum ActorVM {
    // 演员人气榜攒的名字→账号桥(进过演员段就越来越准)
    static var uidByName: [String: String] = [:]
    @MainActor
    static func lookup(_ name: String) async -> String {
        if let u = uidByName[name], !u.isEmpty { return u }
        guard let c = Hongguo.client else { return "" }
        var cursor: String?
        for _ in 0..<5 {                                  // 最多扒 5 页 ≈ 75 位头部演员
            let sr = try? await Hongguo.attempt(c, {
                try await c.shortRank(ShortRankQuery(content: "ranklist_celebrity",
                                                     cursor: cursor))
            })
            guard let sr else { break }
            for it in sr.items where !it.actor.isEmpty && !it.userId.isEmpty {
                uidByName[it.actor] = it.userId
            }
            if let u = uidByName[name], !u.isEmpty { return u }
            cursor = sr.hasMore ? sr.cursor : nil
            if cursor == nil { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return ""
    }
}

// MARK: - 演员榜段 + 演员主页

@MainActor
final class CastVM: ObservableObject {
    @Published var items: [RankItem] = []
    @Published var busy = false
    @Published var note = ""
    // v1.10.63 演员榜分男/女: 榜接口自己不分级, 但演员主页 tags=[男演员/女演员] 是真身
    // → 扫个人页补一本性别账(UserDefaults 持久化, 扫过不重扫)
    @Published var genders: [String: String] = [:]      // uid -> M/F/?
    @Published var genderBusy = false
    private var cursor: String?
    private var pages = 0

    func load() {
        cursor = nil
        pages = 0
        fetch(reset: true)
    }
    func more() {
        guard cursor != nil, !busy, pages < 5 else { return }   // 性别过滤后列表短, 防 v59 永动机
        fetch(reset: false)
    }
    private func fetch(reset: Bool) {
        guard !busy else { return }
        busy = true; if reset { note = "" }
        let cur = reset ? nil : cursor
        Task {
            defer { busy = false }
            guard let c = Hongguo.client,
                  let sr = try? await Hongguo.attempt(c, {
                      try await c.shortRank(ShortRankQuery(content: "ranklist_celebrity", cursor: cur))
                  }) else {
                if reset { self.note = "演员榜没搭手，下拉再来" }
                return
            }
            if reset { self.items = sr.items } else { self.items += sr.items }
            for it in sr.items where !it.actor.isEmpty && !it.userId.isEmpty {
                ActorVM.uidByName[it.actor] = it.userId
            }
            CoverBank.registerRank(sr.items)
            self.pages += 1
            self.cursor = sr.hasMore ? sr.cursor : nil
            if self.items.isEmpty { self.note = "榜上空空的" }
        }
    }

    // 性别补账: 三路并发 Person, 250ms 限速; 75 位 ≈ 8 秒扫完, 之后总/男/女秒切
    func fillGenders() async {
        guard !genderBusy else { return }
        if genders.isEmpty,
           let m = UserDefaults.standard.dictionary(forKey: "hgActorGenders") as? [String: String] {
            genders = m
        }
        let todo = items.filter { !$0.userId.isEmpty && genders[$0.userId] == nil }
        guard !todo.isEmpty, let c = Hongguo.client else { return }
        genderBusy = true
        defer { genderBusy = false }
        var lanes: [[RankItem]] = [[], [], []]
        for (i, it) in todo.enumerated() { lanes[i % 3].append(it) }
        await withTaskGroup(of: Void.self) { tg in
            for lane in lanes {
                tg.addTask { await self.scanLane(lane) }
            }
        }
        UserDefaults.standard.set(genders, forKey: "hgActorGenders")
        HGTrail.note("hgcast 性别账=\(genders.count)")
    }

    // addTask 的 @Sendable 闭包碰不了 MainActor 属性(CI 铁证), 真活挪进本 actor 方法
    private func scanLane(_ lane: [RankItem]) async {
        guard let c = Hongguo.client else { return }
        for it in lane {
            let p = try? await Hongguo.attempt(c, { try await c.person(it.userId) })
            let tag = p?.tags.first(where: { $0.contains("男") || $0.contains("女") }) ?? ""
            genders[it.userId] = tag.contains("男") ? "M" : (tag.contains("女") ? "F" : "?")
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

@MainActor
final class ActorWorksVM: ObservableObject {
    @Published var p: Person?
    @Published var works: [Work] = []
    @Published var busy = false
    @Published var note = ""
    private var cursor: String?
    private var uid = ""

    func load(_ u: String) {
        guard uid != u else { return }
        uid = u
        Task {
            guard let c = Hongguo.client else { return }
            busy = true
            defer { busy = false }
            if let pg = try? await Hongguo.attempt(c, { try await c.personWorks(u) }) {
                CoverBank.registerWorks(pg.items)
                works = pg.items
                cursor = pg.hasMore ? pg.cursor : nil
            }
            if let per = try? await Hongguo.attempt(c, { try await c.person(u) }) {
                p = per
            }
            if works.isEmpty { note = "作品暂时没拉到手（风控抖动可退出重进）" }
        }
    }
    func more() {
        guard let cursor, !busy else { return }
        busy = true
        let cur = cursor
        Task {
            defer { busy = false }
            guard let c = Hongguo.client,
                  let pg = try? await Hongguo.attempt(c, { try await c.personWorks(self.uid, cursor: cur) }) else { return }
            CoverBank.registerWorks(pg.items)
            self.works += pg.items
            self.cursor = pg.hasMore ? pg.cursor : nil
        }
    }
}

// MARK: - 发现(现选+搜索+热搜猜词)

@MainActor
final class DiscoverVM: ObservableObject {
    @Published var rows: [SeriesSummary] = []
    @Published var query = ""
    @Published var guesses: [String] = []
    @Published var hotBoards: [HotBoard] = []
    @Published var suggests: [String] = []
    private var sugSeq = 0
    @Published var busy = false
    @Published var note = ""
    private var nextCursor: String?
    private var mode = ""          // ""发现 / 搜索词

    func load(reset: Bool = true) {
        if reset { nextCursor = nil }
        guard !busy else { return }
        busy = true; if reset { note = "" }
        let cur = nextCursor
        Task {
            defer { busy = false }
            guard let c = Hongguo.client else { note = "红果引擎未就绪"; return }
            let isSearch = !mode.isEmpty
            if let pg = try? await Hongguo.attempt(c, {
                isSearch ? try await c.search(mode) : try await c.discover(Openhongguo.DiscoverOptions(cursor: cur))
            }) {
                CoverBank.register(pg.items)
                if reset { rows = pg.items } else { rows += pg.items }
                nextCursor = pg.hasMore ? pg.cursor : nil
                if rows.isEmpty { note = isSearch ? "搜不到「\(mode)」，换个词试试" : "目录暂时空手（风控抖动，下拉再来）" }
            } else { note = "目录口这次没搭手，下拉重试" }
        }
        if guesses.isEmpty && hotBoards.isEmpty {
            Task { await fetchHot() }
        }
    }

    // 红果热搜: 猜词 + 头两张热榜(给全页搜索用)
    func fetchHot() async {
        guard let c = Hongguo.client,
              let hs = try? await Hongguo.attempt(c, { try await c.hotSearch() }) else { return }
        guesses = Array(hs.guesses.prefix(10).map(\.title))
        hotBoards = Array(hs.boards.filter { !$0.items.isEmpty && $0.name != "热点话题榜" }.prefix(2))
    }

    func run(_ q: String) {
        mode = q.trimmingCharacters(in: .whitespacesAndNewlines)
        load()
    }

    // 搜索独立水道(v1.10.29 修叠加冤案: 与首页 discover 共池导致推荐页被
    // 自动翻页一路 append 进搜索结果, 分开后各走各的游标)
    @Published var sres: [SeriesSummary] = []
    @Published var snote = ""
    @Published var sbusy = false
    private var scur: String?
    private var smode = ""

    // v1.10.51 搜索频道 tab(照 iDuanJu 胶囊行): 0=短剧(默认) 1=漫剧 2=AI剧 3=影视
    static let filterVals = ["content_type_short_play", "content_type_dynamic_comic",
                             "content_type_ai_dynamic_comic", "content_type_long_video"]
    @Published var sfilter = 0
    func setFilter(_ i: Int) {
        guard i != sfilter else { return }
        sfilter = i
        HGTrail.note("hgsearch filter=\(i)")
        if !smode.isEmpty { doSearch(smode) }
    }

    func doSearch(_ q: String) {        smode = q.trimmingCharacters(in: .whitespacesAndNewlines)
        HGTrail.note("hgsearch go '\(smode.prefix(20))'")
        guard !smode.isEmpty else { sres = []; snote = ""; return }
        rememberHist(smode)
        // v1.10.42 二次搜索叠加案: 旧页还在路上时发起新搜索, 旧结果晚到会把
        // 新结果"顶"成追加。换代号(gen), 迟到的旧页直接作废; 列表立刻清空重开
        sgen &+= 1
        fetchSearch(reset: true, gen: sgen)
    }
    private var sgen = 0

    // 搜索历史(照 iDuanJu 历史搜索 chips, v1.10.39): 最近10条, 一键清空
    @Published var shist: [String] = UserDefaults.standard.stringArray(forKey: "hgSearchHist") ?? []
    func rememberHist(_ t: String) {
        var a = shist
        a.removeAll { $0 == t }
        a.insert(t, at: 0)
        if a.count > 10 { a = Array(a.prefix(10)) }
        shist = a
        UserDefaults.standard.set(a, forKey: "hgSearchHist")
    }
    func clearHist() {
        shist = []
        UserDefaults.standard.removeObject(forKey: "hgSearchHist")
    }

    func moreSearch() {
        guard scur != nil, !sbusy else { return }
        fetchSearch(reset: false, gen: sgen)
    }

    var searchHasMore: Bool { scur != nil }

    private func fetchSearch(reset: Bool, gen: Int) {
        if !reset { guard !sbusy else { return } }
        sbusy = true
        if reset { snote = ""; sseen = []; sres = []; scur = nil }
        let q = smode
        let cur = reset ? nil : scur
        Task {
            guard let c = Hongguo.client else {
                if gen == self.sgen { snote = "红果引擎未就绪"; sbusy = false }
                return
            }
            // v1.10.42 纯短剧口: filters=content_type_short_play(Go SDK 实测常量, 官网搜索
            // 默认就是这条 tab)。文章/合集/小说从源头不再混入, eps=0 客户端过滤降为兜底。
            // 注意: 游标不携带筛选, 续页必须原样带上同一 filters(SDK 文档明言)。
            // v1.10.52 频道筛选(v1.52 勘误: 此功能实际随 51 版首发, 见 git 记录):
            // 照 iDuanJu 搜索页"真人剧|漫剧|AI剧|影视"胶囊行, 值用 Go SDK 实测常量。
            // 游标不携筛选, 所以续页原样带同一组(SDK 文档明言)。
            let fval = Self.filterVals[max(0, min(sfilter, 3))]
            let opt = SearchOptions(cursor: cur, pageSize: 20, filters: [fval])
            var pg: Page<SeriesSummary>?
            for k in 0..<3 {
                pg = try? await c.search(q, options: opt)
                if pg != nil { break }
                if k < 2 { try? await Task.sleep(nanoseconds: k == 0 ? 1_600_000_000 : 3_200_000_000) }
            }
            guard gen == self.sgen else { return }     // 已被更新的搜索接管, 迟到页整包作废
            sbusy = false
            if let pg = pg {
                var items = pg.items
                // 文章/合集/演员假号行兜底(PC 探针画像: 这些行 episodeCount 恒 0)
                let raw0 = items.count
                items = items.filter { $0.episodeCount > 0 }
                let dropped = raw0 - items.count
                // 防重铁闸: 服务端游标偶尔犯浑给重复行, 已见过的直接丢
                items = items.filter { sseen.insert($0.id).inserted }
                CoverBank.register(items)
                for i in items.indices where items[i].coverUrl.isEmpty {
                    if let c2 = CoverBank.data[items[i].id] { items[i].coverUrl = c2 }
                }
                if reset { self.sres = items } else { self.sres += items }
                // v1.10.44 加餐改无条件(PC 回看实锤: content_type_short_play 把演员行
                // 也筛掉了, 43 版"搜索行里找演员"的探针永远扑空)。每次新搜索后台都
                // 查一次人气榜身份, 有戏就加餐, 没戏静默; 查询结果进程内记忆不重烧
                if reset, sfilter == 0 { actorBonus(q) }
                // v1.10.43 断头绳(PC -sdeep 40页实锤: 演员类查询服务端只有约20部,
                // hasMore 却永远 true、从第3页起全量轮回旧剧—不给断头绳能翻到地老天荒
                // "看着多其实不全"。规则: 游标自我复制或整页零新剧, 当场收线)
                let nc = pg.cursor ?? ""
                let stale = pg.hasMore && (items.isEmpty || nc == (cur ?? ""))
                self.scur = (pg.hasMore && raw0 > 0 && !stale) ? pg.cursor : nil
                HGTrail.note("hgsearch back '\(q.prefix(12))' n=\(items.count) drop=\(dropped) more=\(pg.hasMore) total=\(self.sres.count) nocover=\(items.filter { $0.coverUrl.isEmpty }.count)\(stale ? " STALL-CUT" : "")")
                if self.sres.isEmpty { self.snote = "搜不到「\(q)」，换个词试试" }
                await self.fillCovers(Array(items.prefix(8)))
            } else { self.snote = "搜索口这次没搭手，再来一次" }
        }
    }
    private var sseen: Set<String> = []

    // v1.10.43 演员加餐: 查询词命中演员(搜索行 title==词 且 eps=0)时, 后台走
    // 人气榜uid桥(ActorVM.lookup, 演员tab同款已验证)→personWorks 全量翻页,
    // 把 TA 的所有作品(去重后)拼进搜索结果 = 红果只给19部精选的补全方案
    private var actorBonusDone = ""
    private static var uidMemo: [String: String] = [:]   // 名字→榜uid 进程内记忆(空串=查过没有)
    private func actorBonus(_ name: String) {
        guard actorBonusDone != name else { return }
        actorBonusDone = name
        Task { @MainActor in
            guard let c = Hongguo.client else { return }
            var uid = DiscoverVM.uidMemo[name] ?? ""
            if DiscoverVM.uidMemo[name] == nil {
                uid = await ActorVM.lookup(name)
                DiscoverVM.uidMemo[name] = uid
            }
            guard !uid.isEmpty else {
                HGTrail.note("hgsearch actor noUid '\(name)'")
                return
            }
            var all: [Work] = []
            var cur = ""
            for _ in 0..<4 {
                let pg = try? await (cur.isEmpty
                    ? c.personWorks(uid)
                    : c.personWorks(uid, cursor: cur))
                guard let pg = pg, !pg.items.isEmpty else { break }
                all += pg.items
                guard pg.hasMore else { break }
                let n = pg.cursor
                if n.isEmpty || n == cur { break }
                cur = n
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard name == self.smode else { return }   // 用户已换词, 别去搅新战场
            let extra = all.filter { $0.episodeCount > 0 }
                .map { SeriesSummary(id: $0.seriesId, title: $0.title, description: $0.description,
                                     coverUrl: $0.coverUrl, coverExpiresAt: $0.coverExpiresAt,
                                     episodeCount: $0.episodeCount) }
                .filter { sseen.insert($0.id).inserted }
            guard !extra.isEmpty else {
                HGTrail.note("hgsearch actor works0 uid=\(uid)")
                return
            }
            CoverBank.register(extra)
            self.sres += extra
            HGTrail.note("hgsearch actor+\(extra.count) uid=\(uid) total=\(self.sres.count)")
        }
    }

    // 银行也空着的封面: 去详情口一张张贴回来(限量, 温和限速)
    private func fillCovers(_ batch: [SeriesSummary]) async {
        guard let c = Hongguo.client else { return }
        var done = 0
        for s in batch where s.coverUrl.isEmpty && !s.id.isEmpty {
            if done >= 8 { break }
            // 演员假号/下架剧会炸, 单部失败跳过继续; 目录口从未被风控, 直连不吃四段退避
            let sv = try? await c.getSeries(s.id)
            if let sv, !sv.coverUrl.isEmpty {
                CoverBank.put(s.id, sv.coverUrl)
                if let i = sres.firstIndex(where: { $0.id == s.id }) { sres[i].coverUrl = sv.coverUrl }
            }
            done += 1
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    // 输入联想(开心果同款 300ms 防抖, 调用方 task(id:) 里睡够再喊)
    func suggest(_ p: String) {
        let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { suggests = []; return }
        sugSeq += 1
        let my = sugSeq
        guard let c = Hongguo.client else { return }
        Task {
            let s = try? await Hongguo.attempt(c, { try await c.suggest(t) })
            if my == sugSeq { suggests = Array((s ?? []).prefix(8).map { $0.text }) }
        }
    }

    func more() {
        guard nextCursor != nil, !busy else { return }
        load(reset: false)
    }
}

// MARK: - 榜单(内容×榜单两级 chips)

@MainActor
final class RankVM: ObservableObject {
    @Published var contents: [RankContent] = []
    @Published var items: [RankItem] = []
    @Published var content = ""
    @Published var board = ""
    @Published var busy = false
    @Published var note = ""
    private var nextCursor: String?

    func load(content: String? = nil, board: String? = nil) {
        if let c = content { self.content = c }
        if let b = board { self.board = b }
        nextCursor = nil
        fetch(reset: true)
    }

    func more() {
        guard nextCursor != nil, !busy else { return }
        fetch(reset: false)
    }

    private func fetch(reset: Bool) {
        guard !busy else { return }
        busy = true; if reset { note = "" }
        let q = ShortRankQuery(content: content.isEmpty ? nil : content,
                               board: board.isEmpty ? nil : board,
                               cursor: reset ? nil : nextCursor)
        Task {
            defer { busy = false }
            guard let c = Hongguo.client,
                  let sr = try? await Hongguo.attempt(c, { try await c.shortRank(q) }) else {
                if reset { self.note = "榜单没搭手，稍后再拉" }
                return
            }
            if !sr.contents.isEmpty { self.contents = sr.contents }
            CoverBank.registerRank(sr.items)
            if reset { self.items = sr.items } else { self.items += sr.items }
            self.nextCursor = sr.hasMore ? sr.cursor : nil
            if self.items.isEmpty { self.note = "这张榜暂时空的" }
        }
    }
}

// MARK: - 上新日历

@MainActor
final class NewVM: ObservableObject {
    @Published var dates: [String] = []
    @Published var date = ""          // YYYYMMDD, 空=服务端默认(今天)
    @Published var items: [NewRelease] = []
    @Published var busy = false
    @Published var note = ""
    private var nextCursor: String?

    func load(date: String? = nil) {
        if let d = date { self.date = d }
        nextCursor = nil
        fetch(reset: true)
    }

    func more() {
        guard nextCursor != nil, !busy else { return }
        fetch(reset: false)
    }

    private func fetch(reset: Bool) {
        guard !busy else { return }
        busy = true; if reset { note = "" }
        let q = NewReleaseQuery(date: date.isEmpty ? nil : date,
                                cursor: reset ? nil : nextCursor)
        Task {
            defer { busy = false }
            guard let c = Hongguo.client,
                  let pg = try? await Hongguo.attempt(c, { try await c.newReleases(q) }) else {
                if reset { self.note = "上新日历没搭手，稍后再拉" }
                return
            }
            self.dates = pg.dates
            CoverBank.registerNew(pg.items)
            if self.date.isEmpty { self.date = pg.date }
            if reset { self.items = pg.items } else { self.items += pg.items }
            self.nextCursor = pg.hasMore ? pg.cursor : nil
            if self.items.isEmpty { self.note = "这天暂无排期" }
        }
    }
}

// MARK: - 分类筛选墙

@MainActor
final class CatVM: ObservableObject {
    @Published var panel: [FilterRow] = []
    @Published var picks: [String: String] = [:]     // 每行单选(官方支持多选, v1 克制)
    @Published var rows: [SeriesSummary] = []
    @Published var busy = false
    @Published var note = ""
    private var nextCursor: String?

    func loadPanel() {
        guard panel.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let c = Hongguo.client,
                  let p = try? await Hongguo.attempt(c, { try await c.shortFilterPanel("") }) else {
                note = "筛选墙没搭手"; busy = false
                return
            }
            panel = p
            if !p.isEmpty {
                board()
            } else { note = "筛选墙空的" }
        }
    }

    func pick(key: String, value: String) {
        if picks[key] == value { picks[key] = nil } else { picks[key] = value }
        board()
    }

    // v1.10.70 "全部XX"胶囊 = 清掉这一行的条件
    func clearKey(_ key: String) {
        guard picks[key] != nil else { return }
        picks[key] = nil
        board()
    }

    func more() {
        guard nextCursor != nil, !busy else { return }
        board(reset: false)
    }

    private func board(reset: Bool = true) {
        guard !busy || !reset else { return }
        if reset { note = "" }
        let sel = picks.reduce(into: [String: [String]]()) { $0[$1.key] = [$1.value] }
        let q = ShortFilterQuery(selections: sel.isEmpty ? nil : sel,
                                 cursor: reset ? nil : nextCursor)
        Task {
            defer { busy = false }
            guard let c = Hongguo.client,
                  let pg = try? await Hongguo.attempt(c, { try await c.shortFilter(q) }) else {
                if reset { self.note = "这一挂暂时没搭手" }
                return
            }
            CoverBank.register(pg.items)
            if reset { self.rows = pg.items } else { self.rows += pg.items }
            self.nextCursor = pg.hasMore ? pg.cursor : nil
            if self.rows.isEmpty { self.note = "这组合下没有剧，松一两个条件试试" }
        }
    }
}

// MARK: - 主页: 一级 tab "场"(v1.10.26 升格), 红果式顶部页签 + 首页 hero 轮播

struct TheaterHomeView: View {
    @State private var seg = 0
    @StateObject private var disc = DiscoverVM()
    @StateObject private var rank = RankVM()
    @StateObject private var news = NewVM()
    @StateObject private var cat = CatVM()
    @StateObject private var cast = CastVM()
    @StateObject private var rails = RailVM()
    @StateObject private var nav = TheaterNav.shared
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // v1.10.63 首页=榜单页(用户钦点照 iDuanJu 榜单屏): 分类胶囊(演员榜+服务端
                // 自述五类) + 榜切片 + 列表; 演员榜并入第一类(总/男/女). 旧首页 DiscoverTab
                // (轮播+推荐)与原演员 tab 退役, struct 留档随时复活
                RankTab(vm: rank, cast: cast, cat: cat)
            }
            .navigationTitle("剧场")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { nav.openSearch("mag") } label: { Image(systemName: "magnifyingglass") }
                }
            }
            .task {
                if rank.contents.isEmpty { rank.load() }
            }
            .theaterRoutes(disc, rails)
        }
        .environmentObject(nav)
        .onAppear { nav.bind = $path }
        .theaterRoutes(disc, rails)
    }
}

// 右上放大镜: 红果同款全页搜索(猜词+热搜榜)
// 目的地注册(iDuanJu routes() 同款): 单一 Route 枚举一份注册, 钉在栈根内容上
// v1.10.41: 搜索页收编进 Route 值跳转, 全栈再无 view-style 混编(治侧滑串页)
extension View {
    func theaterRoutes(_ disc: DiscoverVM, _ rails: RailVM) -> some View {
        navigationDestination(for: TheaterNav.Route.self) { r in
            switch r {
            case .want(let w): TheaterDetailView(want: w)
            case .actorGo(let a): ActorPage(uid: a.uid, name: a.name)
            case .actor(let a): ActorResolveView(name: a.name)
            case .search: TheaterSearchTab(vm: disc, rails: rails)
            }
        }
    }
}

// v1.10.55 iDuanJu 1:1 抄码(GPL 私用不分发 用户钦定"直接抄"):
// TopRankCard = ZStack(bottom){封面 + 名次专属渐变(红1蓝2橙3) mask(0.35起渐黑) +
// 白字 TOP N 24黑圆体/标题/热度} aspect0.6 圆12; 小卡抄 NumberedPosterCell:
// 3:4 竖图 + 左上 %02d 26黑斜体圆体描影 + 底部渐黑 + 图下标题
enum IdjRankStyle {
    static func gradient(_ r: Int) -> LinearGradient {
        let c: [Color]
        switch r {
        case 1: c = [Color(red: 0.95, green: 0.25, blue: 0.3), Color(red: 0.75, green: 0.1, blue: 0.2)]
        case 2: c = [Color(red: 0.25, green: 0.35, blue: 0.95), Color(red: 0.15, green: 0.2, blue: 0.7)]
        default: c = [Color(red: 0.98, green: 0.45, blue: 0.25), Color(red: 0.85, green: 0.25, blue: 0.15)]
        }
        return LinearGradient(colors: c, startPoint: .top, endPoint: .bottom)
    }
    static func numeralColor(_ r: Int) -> Color {
        switch r {
        case 1: return Color(red: 1, green: 0.27, blue: 0.2)
        case 2: return Color(red: 1, green: 0.55, blue: 0.15)
        case 3: return Color(red: 1, green: 0.78, blue: 0.2)
        default: return .white.opacity(0.85)
        }
    }
}

struct TopBoards: View {
    @ObservedObject var rails: RailVM
    var body: some View {
        let cards = rails.hot
        return VStack(alignment: .leading, spacing: 12) {
            if cards.isEmpty {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .aspectRatio(0.6, contentMode: .fit)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.12)))
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(cards.prefix(3).enumerated()), id: \.offset) { i, c in
                        TopRankCardBig(rank: i + 1, card: c)
                            .frame(maxWidth: .infinity)
                    }
                }
                // v1.10.56 他家搜索页 4-20 = 两列短图列表(CompactRankRow 真身),
                // 不是五列竖卡网格(NumberedPosterCell 是他家首页件 又拿错零件)
                if cards.count > 3 {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 12) {
                        ForEach(Array(cards.dropFirst(3).enumerated()), id: \.offset) { i, c in
                            CompactRankRow(rank: i + 4, card: c)
                        }
                    }
                }
            }
        }
        .task { rails.load() }
    }
}

// 热度黑胶囊(官方红果同款 白字黑55% 贴封面左下)
private struct HeatTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
    }
}

private struct TopRankCardBig: View {
    @EnvironmentObject private var nav: TheaterNav
    let rank: Int
    let card: HRail.CardLike
    var body: some View {
        Button { nav.go(HgWant(sid: card.sid, title: card.title), "top " + card.sid) } label: {
            ZStack(alignment: .bottom) {
                // v1.10.58 三卡等高修法(用户"TOP3和TOP1/2高度不对"): 各封面原始比例
                // 不同会各自顶高度, 先垫 0.6 透明底座定形(v.9.50 铁律), 封面
                // scaledToFill 溢出的部分由外层 clipShape 剪掉
                Color.clear.aspectRatio(0.6, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: URL(string: hgCoverUrl(sid: card.sid, card.cover))) {
                            $0.resizable().scaledToFill()
                        } placeholder: { Color.clear }
                    }
                IdjRankStyle.gradient(rank)
                    .mask(LinearGradient(colors: [.clear, .black, .black],
                                         startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom))
                VStack(spacing: 3) {
                    Text("TOP" + String(rank))
                        .font(.system(size: 30, weight: .black, design: .rounded))
                    Text(card.title)
                        .font(.system(size: 13, weight: .bold)).lineLimit(1)
                    if !card.sub.isEmpty {
                        Text(card.sub).font(.system(size: 11)).opacity(0.8).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.bottom, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// iDuanJu CompactRankRow 逐行移植(他家搜索页 4-20 真身: 两列 小图+右上名次章+
// 标题+红字热度; 名次章前三用金银铜色 其余中国红)
private struct CompactRankRow: View {
    @EnvironmentObject private var nav: TheaterNav
    let rank: Int
    let card: HRail.CardLike
    var body: some View {
        Button { nav.go(HgWant(sid: card.sid, title: card.title), "top " + card.sid) } label: {
            HStack(spacing: 10) {
                Color.clear.frame(width: 46, height: 62)
                    .overlay {
                        AsyncImage(url: URL(string: hgCoverUrl(sid: card.sid, card.cover))) {
                            $0.resizable().scaledToFill()
                        } placeholder: { Color.gray.opacity(0.2) }
                    }
                    .overlay(alignment: .topTrailing) {
                        Text(String(rank))
                            .font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(rank <= 3 ? IdjRankStyle.numeralColor(rank)
                                                   : Color(red: 0.8, green: 0.15, blue: 0.25),
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 6) {
                        if !card.sub.isEmpty {
                            Text(card.sub).foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.25))
                        }
                    }
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}
private struct TheaterSearchTab: View {
    @ObservedObject var vm: DiscoverVM
    @ObservedObject var rails: RailVM
    @State private var q = ""
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜红果剧名 / 演员", text: $q)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { vm.doSearch(q) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.12)))
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                // v1.10.51 频道胶囊行(照 iDuanJu 搜索页"真人剧|漫剧|AI剧|影视"):
                // 点频道=换搜索池, 结果立刻按所选频道重查; 短剧=默认即原行为
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(["短剧", "漫剧", "AI剧", "影视"].enumerated()), id: \.offset) { i, name in
                            let on = vm.sfilter == i
                            Button { vm.setFilter(i) } label: {
                                Text(name)
                                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.orange : Color.primary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(Capsule().fill(on ? Color.orange.opacity(0.13)
                                                                : Color.gray.opacity(0.10)))
                                    .overlay(Capsule().strokeBorder(on ? Color.orange.opacity(0.55)
                                                                     : Color.clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8))
                // 三张 TOP 大卡(v1.10.52 用户钦点): 没出结果时就是它仨当家, 出的结果秒让位
                if vm.sres.isEmpty {
                    TopBoards(rails: rails)
                        .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 8, trailing: 2))
                        .listRowBackground(Color.clear)
                }
                if vm.sres.isEmpty {
                    if vm.guesses.isEmpty && vm.hotBoards.isEmpty && vm.shist.isEmpty {
                        Button("拉一下红果热搜 🔥") { Task { await vm.fetchHot() } }
                            .font(.footnote)
                    }
                    if !vm.shist.isEmpty {
                        Section {
                            HStack {
                                Text("历史搜索")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    vm.clearHist()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
                            FlowGuess(words: vm.shist) { q = $0; vm.doSearch($0) }
                                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    }
                    if !vm.guesses.isEmpty {
                        Section {
                            HStack {
                                Text("搜索发现")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
                            FlowGuess(words: vm.guesses) { q = $0; vm.doSearch($0) }
                                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    }
                // v1.10.57 热搜榜/预约榜整段拆除(用户点单: 搜索页只留 TOP 区+历史+猜词)
                }
            }
            if !vm.snote.isEmpty {
                Section { Text(vm.snote).font(.caption).foregroundStyle(.secondary) }
            }
            if !q.isEmpty && !vm.suggests.isEmpty && vm.sres.isEmpty {
                Section("你是想搜这些吗") {
                    ForEach(vm.suggests, id: \.self) { s in
                        Button { q = s; vm.doSearch(s) } label: {
                            Label(s, systemImage: "magnifyingglass")
                                .font(.subheadline)
                        }
                    }
                }
            }
            if vm.sbusy && !q.isEmpty && vm.sres.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("搜索中…").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            if !vm.sres.isEmpty {
                Section("搜索结果") {
                    // 搜索页绝不自动翻页(v1.10.33 用户实锤: 结果只有5张时
                    // 任何 onAppear 都触发续页, 列表当场膨胀重排, 手指按下去
                    // 详情页被布局抖动弹回=闪一下+返回连弹冤案)
                    // 懒加载回来了(v1.10.40): 33 版封它是因为 NavigationLink 会被列表膨胀
                    // 抖断(闪屏案); 38 换 Button+程序化栈后膨胀无害, 照 iDuanJu 滚到
                    // 尾 4 格自动续页, 底部按钮留作兜底
                    Grid2Cards(rows: vm.sres, nearEnd: { i in
                        if i >= vm.sres.count - 4 { vm.moreSearch() }
                    })
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    if vm.sbusy {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if vm.searchHasMore {
                        // 滑到底自动续页(v1.10.41): List 里"卡片 onAppear"不可靠(行级虚拟化),
                        // 改把哨兵挂在底部这一行上——它一进视野就自动翻页, 手点按钮仍是兜底
                        Button { vm.moreSearch() } label: {
                            Text("加载更多").font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .onAppear { vm.moreSearch() }
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if vm.guesses.isEmpty { Task { await vm.fetchHot() } } }
        .task(id: q) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vm.suggests = []
            } else {
                vm.suggest(q)
            }
        }
    }
}

// 红果同款双列竖卡(一屏两部的命根子; 固定比例底座铁律 v1.9.50 遗产)
private struct Grid2Cards: View {
    @EnvironmentObject private var nav: TheaterNav
    let rows: [SeriesSummary]
    var rank0 = 0                                   // >0 则从 rank0 起挂奖牌徽章
    var nearEnd: (Int) -> Void = { _ in }           // 滚到尾部自动续页
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                Button { nav.go(HgWant(sid: s.id, title: s.title), "grid " + s.id) } label: {
                    // v1.10.73 用户钦定: 剧名搬出封面, 图是图字是字; 黑渐隐卸装, 列距 8→10
                    VStack(alignment: .leading, spacing: 5) {
                        Color.clear.aspectRatio(0.7, contentMode: .fit)
                            .overlay {
                                AsyncImage(url: URL(string: hgCoverUrl(sid: s.id, s.coverUrl))) {
                                    $0.resizable().scaledToFill()
                                } placeholder: {
                                    LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.12)],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if rank0 > 0 {
                                    RankBadge2(rank: rank0 + i).padding(6)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            }
                        Text(s.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(2)
                        Text(hgGridSub(s)).font(.system(size: 10))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .onAppear { nearEnd(i) }
            }
        }
        .padding(.horizontal, 2)
    }
}

func hgGridSub(_ s: SeriesSummary) -> String {
    var out = s.episodeCount > 0 ? "全\(s.episodeCount)集" : "短剧"
    if !s.category.isEmpty { out += " · " + s.category }
    if !s.author.isEmpty { out += " · " + s.author }
    return out
}

func hgToday() -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd"
    return f.string(from: Date())
}

// 双列竖卡的通用版(上新/演员作品等拿不到 SeriesSummary 的场合)
struct Grid2Lite: View {
    @EnvironmentObject private var nav: TheaterNav
    let items: [HRail.CardLike]
    var rank0 = 0
    var nearEnd: (Int) -> Void = { _ in }
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                Button { nav.go(HgWant(sid: c.sid, title: c.title), "lite " + c.sid) } label: {
                    // v1.10.73 剧名搬家同款式(与 Grid2Cards 一个语言)
                    VStack(alignment: .leading, spacing: 5) {
                        Color.clear.aspectRatio(0.7, contentMode: .fit)
                            .overlay {
                                AsyncImage(url: URL(string: hgCoverUrl(sid: c.sid, c.cover))) {
                                    $0.resizable().scaledToFill()
                                } placeholder: { Color.gray.opacity(0.16) }
                            }
                            .overlay(alignment: .topLeading) {
                                if rank0 > 0 {
                                    RankBadge2(rank: rank0 + i).padding(6)
                                } else if c.rank > 0 {
                                    RankBadge2(rank: c.rank).padding(6)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            }
                        Text(c.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(2)
                        Text(c.sub).font(.system(size: 10))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .onAppear { nearEnd(i) }
            }
        }
        .padding(.horizontal, 2)
    }
}

// 通用小组件

private struct ChipScroller: View {
    var labels: [(String, Bool)]
    var onPick: (Int) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, pair in
                    Button {
                        onPick(i)
                    } label: {
                        Text(pair.0)
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(pair.1 ? Color.orange.opacity(0.9) : Color.gray.opacity(0.18)))
                            .foregroundStyle(pair.1 ? .white : .primary)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct ShowRow: View {
    @EnvironmentObject private var nav: TheaterNav
    let sid: String
    let title: String
    let sub: String
    let cover: String
    var badge: String? = nil

    var body: some View {
        Button { nav.go(HgWant(sid: sid, title: title), "show " + sid) } label: {
            HStack(spacing: 10) {
                if let b = badge {
                    Text(b)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .frame(width: 26, alignment: .center)
                        .foregroundStyle(b.count <= 2 ? Color.orange : Color.secondary)
                }
                AsyncImage(url: URL(string: hgCoverUrl(sid: sid, cover))) { $0.resizable().scaledToFill() }
                    placeholder: { Color.gray.opacity(0.15) }
                    .frame(width: 52, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline).lineLimit(1)
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct MoreButton: View {
    let busy: Bool
    let more: () -> Void
    var body: some View {
        Button(action: more) {
            HStack {
                Spacer()
                if busy { ProgressView() } else { Text("加载更多 ↓").font(.footnote).foregroundStyle(.secondary) }
                Spacer()
            }
        }
        .disabled(busy)
    }
}

// MARK: - 首页段(红果式: 顶部大卡轮播 + 热剧 feed)

private struct HeroCarousel: View {
    @EnvironmentObject private var nav: TheaterNav
    let rows: [SeriesSummary]
    @State private var idx = 0
    var body: some View {
        // v1.10.45 轮播大改(用户"光一张裁切的图什么信息都没有看着膈应"):
        // 改红果官网信息卡姿势=氛围虚化背景 + 左侧完整海报(不裁) + 右侧
        // 标题/分类集数/简介两行/立即观看橙钮, 一眼看懂推的是什么
        TabView(selection: $idx) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                Button { nav.go(HgWant(sid: s.id, title: s.title), "hero " + s.id) } label: {
                    ZStack {
                        // 圆角底垫(v1.10.49 升级到 20 continuous 苹果标准圆)
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        AsyncImage(url: URL(string: s.coverUrl)) {
                            $0.resizable().scaledToFill()
                                .blur(radius: 40)
                                .overlay(Color.black.opacity(0.38))
                                .overlay(
                                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35)],
                                                   startPoint: .top, endPoint: .bottom)
                                )
                        } placeholder: {
                            LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .mask(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: URL(string: s.coverUrl)) {
                                $0.resizable().scaledToFill()
                            } placeholder: { Color.gray.opacity(0.25) }
                            .frame(width: 112, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(.white.opacity(0.25), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                            .overlay(alignment: .bottom) {
                                // iDuanJu 同款: 海报底部"全N集"黑透胶囊
                                if s.episodeCount > 0 {
                                    Text("全" + String(s.episodeCount) + "集")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().fill(.black.opacity(0.55)))
                                        .padding(.bottom, 6)
                                }
                            }
                            let meta = (s.category.isEmpty ? "" : s.category + " · ") +
                                       (s.episodeCount > 0 ? "全" + String(s.episodeCount) + "集" : "红果热映")
                            VStack(alignment: .leading, spacing: 7) {
                                Text("红果短剧")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(.orange.opacity(0.16)))
                                Text(s.title)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text(meta)
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                                if !s.description.isEmpty {
                                    Text(s.description)
                                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                                        .lineLimit(2).lineSpacing(2)
                                }
                                Spacer(minLength: 16)
                                Text("▶  立即观看")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.orange))
                            }
                            .frame(maxWidth: .infinity, maxHeight: 172, alignment: .topLeading)
                        }
                        .padding(14)
                     }
                     .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                 }
                 .buttonStyle(.plain)
                 .tag(i)
             }
         }
         .tabViewStyle(.page(indexDisplayMode: .never))
         .frame(height: 218)
         // v1.10.62 页码真身: 61 挂在每页里被 TabView 分页容器吃掉(49 圆角悬案老坑重现),
         // 改 overlay 钉在 TabView 容器本体=和 clipShape 同层, 谁也吞不了它; 滑页时数字跟着
         // selection 变, 黑透底白字在亮卡片上也立得住
         .overlay(alignment: .bottomTrailing) {
             Text("\(idx + 1)/\(rows.count)")
                 .font(.system(size: 12, weight: .semibold, design: .rounded))
                 .monospacedDigit()
                 .foregroundStyle(.white)
                 .padding(.horizontal, 9).padding(.vertical, 5)
                 .background(Capsule().fill(Color.black.opacity(0.38)))
                 .padding(.trailing, 12)
                 .padding(.bottom, 10)
         }
        // v1.10.49 铁证修法: 页内 clipShape 连吃三版瘪(45/46/48), 改剪 TabView 容器本体
        // ——轮播整体一个圆角模具, 页面在模具里滑动, 想不圆都难
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
private struct DiscoverTab: View {
    @ObservedObject var vm: DiscoverVM
    @ObservedObject var rails: RailVM
    var body: some View {
        List {
            if vm.rows.count >= 3 {
                Section {
                    HeroCarousel(rows: Array(vm.rows.prefix(8)))
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 6, trailing: 6))
                        .listRowBackground(Color.clear)
                }
            }
            if !rails.hot.isEmpty {
                Section {
                    HRail(title: "🔥 热播榜", sub: "红果正在霸屏的", items: rails.hot)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if !rails.fresh.isEmpty {
                Section {
                    HRail(title: "🚀 新剧榜", sub: "刚上架的鲜货", items: rails.fresh)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if !rails.must.isEmpty {
                Section {
                    HRail(title: "🏆 必看榜", sub: "口碑压舱石", items: rails.must)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if !vm.note.isEmpty {
                Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) }
            }
            if vm.rows.isEmpty && vm.busy {
                Section {
                    GridSkeleton().listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            if !vm.rows.isEmpty {
                Section {
                    // v1.10.59 自动翻页废除(用户报"滑到底转圈一直不停, 每次6部, 新卡
                    // 灰底→图切一下视觉一卡一卡"): discover 一页只有 6 条, 推不走
                    // 近尾哨兵 → more() 无限连锁; 照搜索 v.33 铁律改手动加载更多
                    Grid2Cards(rows: vm.rows)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("为你推荐").font(.system(size: 16, weight: .heavy))
                }
            }
        }
        .listStyle(.plain)
        .refreshable { vm.run("") }
    }
}

private struct FlowGuess: View {
    let words: [String]
    let tap: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("🔥").font(.footnote)
                ForEach(words, id: \.self) { w in
                    Button { tap(w) } label: {
                        Text(w).font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

// MARK: - 榜单段

private struct RankTab: View {
    @EnvironmentObject private var nav: TheaterNav
    @ObservedObject var vm: RankVM
    @ObservedObject var cast: CastVM
    @ObservedObject var cat: CatVM
    @State private var topSeg = 2                      // v1.10.68 七胶囊挤成三档: 0=筛选找片 1=演员榜 2=榜单(默认)
    var body: some View {
        VStack(spacing: 8) {
            // 一级三大档(左对齐胶囊组, 选中橙): 服务端的五个内容类收进"榜单"当二级
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    let on = topSeg == i
                    Button {
                        topSeg = i
                        if i == 0 { cat.loadPanel() }
                        if i == 1, cast.items.isEmpty { cast.load() }
                    } label: {
                        Text(["筛选找片", "演员榜", "榜单"][i])
                            .font(.system(size: 15, weight: on ? .bold : .regular))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(on ? Color.orange.opacity(0.16)
                                                         : Color.gray.opacity(0.12)))
                            .foregroundStyle(on ? Color.orange : .primary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            if topSeg == 2 {
                if !vm.contents.isEmpty {
                    ChipScroller(labels: vm.contents.map { ($0.name, $0.id == vm.content || ($0.selected && vm.content.isEmpty)) },
                                 onPick: { vm.load(content: vm.contents[$0].id, board: "") })
                }
                if let cur = vm.contents.first(where: { $0.id == vm.content || $0.selected }),
                   !cur.boards.isEmpty {
                    ChipScroller(labels: cur.boards.map { ($0.name, $0.id == vm.board || ($0.selected && vm.board.isEmpty)) },
                                 onPick: { vm.load(board: cur.boards[$0].id) })
                }
            }
            if topSeg == 0 {
                FilterPage(vm: cat)
            } else if topSeg == 1 {
                ActorBoard(vm: cast)
            } else {
            List {
                if !vm.note.isEmpty { Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) } }
                Section {
                    // v1.10.64 一部一排太占地(用户点单): 改三列竖卡墙一屏九部,
                    // 海报墙三列是钦定规矩; 翻页照 v59 教训走手动加载更多
                    GridRankCards(items: vm.items.filter { !$0.seriesId.isEmpty })
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("红果榜单 · 匿名直连")
                }
            }
            .overlay { if vm.busy && vm.items.isEmpty { ProgressView().controlSize(.large) } }
            .refreshable { vm.load() }
            }
        }
    }

    // 演员/推广行的副标题(ViewBuilder 里不许 var 赋值, 抽函数)
    static func actorSub(_ it: RankItem) -> String {
        var s = ""
        if it.actor.isEmpty {
            s = it.score
        } else {
            if !it.intro.isEmpty { s += it.intro + " · " }
            s += it.score
        }
        if !it.details.isEmpty { s += " · " + it.details.joined(separator: " ") }
        return s
    }
}

// v1.10.63 演员榜(收编原"演员"tab): 总榜|男演员|女演员 三格,
// 性别由 CastVM.fillGenders 扫个人页 tags 补账, 账本持久化二次秒开
// v1.10.64 榜单剧墙: 三列竖卡通用件(海报底座+金银铜牌+底部渐黑+片名集数热度),
// 与推荐墙同身段; 一格一剧 一屏九部
struct GridRankCards: View {
    @EnvironmentObject private var nav: TheaterNav
    let items: [RankItem]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)], spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button { nav.go(HgWant(sid: it.seriesId, title: it.title), "rankwall " + it.seriesId) } label: {
                    // v1.10.73 剧名搬家 + B项间距 8→10(三列挤)
                    VStack(alignment: .leading, spacing: 5) {
                        Color.clear.aspectRatio(0.7, contentMode: .fit)
                            .overlay {
                                AsyncImage(url: URL(string: hgImgURL(it.coverUrl))) {
                                    $0.resizable().scaledToFill()
                                } placeholder: {
                                    LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.12)],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                RankBadge2(rank: it.position).padding(6)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            }
                        Text(it.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(2)
                        let sub = (it.episodeCount > 0 ? "全" + String(it.episodeCount) + "集" : "") +
                                 (it.score.isEmpty ? "" : (it.episodeCount > 0 ? " · " : "") + it.score)
                        if !sub.isEmpty {
                            Text(sub).font(.system(size: 9))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
// v1.10.64 演员榜: 三格开关从 List 行里搬出来钉在顶部(List 行内按钮被行
// 点区吞=用户实测"男演员点不了/切不回总榜"), 榜单条目变长时自动补性别账
private struct ActorBoard: View {
    @EnvironmentObject private var nav: TheaterNav
    @ObservedObject var vm: CastVM
    @State private var seg = 0
    private let wants = ["", "M", "F"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Button {
                        seg = i
                        Task { await vm.fillGenders() }
                    } label: {
                        Text(["总榜", "男演员", "女演员"][i])
                            .font(.footnote.weight(i == seg ? .bold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(i == seg ? Color.orange.opacity(0.16)
                                                                 : Color.gray.opacity(0.12)))
                            .foregroundStyle(i == seg ? Color.orange : .primary)
                    }
                }
                if vm.genderBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            List {
                Section {
                    let rows = wants[seg].isEmpty ? vm.items : vm.items.filter { vm.genders[$0.userId] == wants[seg] }
                    if rows.isEmpty {
                        Text(vm.genderBusy ? "正在扫演员性别，稍等…" : "这一档还薄，下拉多拉几位演员")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    // v1.10.66 冠军领奖台(方案图装车): 前三名站金银铜台, 04 起紧凑列表
                    let head = rows.count >= 3 ? Array(rows.prefix(3)) : []
                    let tail = rows.count >= 3 ? Array(rows.dropFirst(3)) : rows
                    if !head.isEmpty {
                        PodiumCard(items: head)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(Array(tail.enumerated()), id: \.offset) { i, it in
                        Button { nav.go(HgActorGo(uid: it.userId, name: it.actor), "actorboard " + it.actor) } label: {
                            HStack(spacing: 10) {
                            // v1.10.66 前三已上台, 列表行号续 04 起(凑不满三台时仍从 01)
                                Text(String(format: "%02d", i + (rows.count >= 3 ? 4 : 1)))
                                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 30)
                                AsyncImage(url: URL(string: hgImgURL(it.avatarUrl))) {
                                    $0.resizable().scaledToFill()
                                } placeholder: { Color.gray.opacity(0.15) }
                                    .frame(width: 46, height: 46)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(it.actor).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(RankTab.actorSub(it))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if i >= rows.count - 3 {
                                vm.more()
                                Task { await vm.fillGenders() }
                            }
                        }
                    }
                } header: {
                    Text("红果演员榜 · 匿名直连").font(.system(size: 15, weight: .heavy))
                }
            }
            .listStyle(.plain)
            .overlay { if vm.busy && vm.items.isEmpty { ProgressView().controlSize(.large) } }
            .refreshable { vm.load(); Task { await vm.fillGenders() } }
        }
        .task { await vm.fillGenders() }
        .onChange(of: vm.items.count) { _ in Task { await vm.fillGenders() } }
    }
}
// v1.10.66 冠军领奖台(用户拍板方案图): 金银铜三阶+冠军居中戴皇冠, 台面烧名字人气
// 头像双保险=底色圈+姓氏字永远打底, 真头像(http→https v60铁律)盖上来, 拉不到也不空白
struct PodiumCard: View {
    @EnvironmentObject private var nav: TheaterNav
    let items: [RankItem]          // 最多前 3 (调用方切好)

    private var cols: [Int] { [1, 0, 2] }        // 列位: 亚 冠 季

    static func podiumColors(_ rank: Int) -> (Color, Color) {
        switch rank {
        case 1: return (Color(red: 0.96, green: 0.77, blue: 0.36), Color(red: 0.84, green: 0.61, blue: 0.16))
        case 2: return (Color(red: 0.78, green: 0.80, blue: 0.84), Color(red: 0.59, green: 0.62, blue: 0.67))
        default: return (Color(red: 0.89, green: 0.62, blue: 0.42), Color(red: 0.73, green: 0.45, blue: 0.26))
        }
    }
    static func popLine(_ it: RankItem?) -> String {
        guard let it else { return "虚位以待" }
        return it.score.isEmpty ? "人气扫描中" : it.score
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<3, id: \.self) { slot in
                podiumCol(cols[slot])
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.orange.opacity(0.12), Color.white.opacity(0.92)],
                                     startPoint: .top, endPoint: .center))
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.5), lineWidth: 1))
    }

    private func podiumCol(_ idx: Int) -> some View {
        let it: RankItem? = idx < items.count ? items[idx] : nil
        let rank = idx + 1
        let c = Self.podiumColors(rank)
        let big = rank == 1
        return VStack(spacing: 6) {
            if big {
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(red: 0.85, green: 0.62, blue: 0.15))
            }
            podiumAvatar(it, r: big ? 44 : 30)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [c.0, c.1], startPoint: .top, endPoint: .bottom))
                    .frame(height: big ? 150 : (rank == 2 ? 118 : 104))
                VStack(spacing: 4) {
                    Text("TOP" + String(rank))
                        .font(.system(size: big ? 22 : 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text(it?.actor ?? "—")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(Self.popLine(it))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if let it, !it.userId.isEmpty {
                nav.go(HgActorGo(uid: it.userId, name: it.actor), "podiumnew " + it.actor)
            }
        }
    }

    private func podiumAvatar(_ it: RankItem?, r: CGFloat) -> some View {
        let actorName = it?.actor ?? "?"
        let initial = String(actorName.prefix(1))
        let base = Circle()
            .fill(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.80)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: r * 2, height: r * 2)
            .overlay(Text(initial)
                .font(.system(size: r * 1.1, weight: .heavy))
                .foregroundStyle(Color(white: 0.45)))
        return AnyView(base.overlay {
            if let u = it?.avatarUrl, !u.isEmpty, let url = URL(string: hgImgURL(u)) {
                AsyncImage(url: url) { ph in
                    ph.image?.resizable().scaledToFill()
                }
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 3)))
    }
}

// v1.10.69 用户点单: 类柱从左边搬到顶上横滑, 屏幕全宽给海报墙, 卡片更大
private struct FilterPage: View {
    @ObservedObject var vm: CatVM

    // 类柱=名字带"类别/频道"的那行, 认不出就拿首行顶上
    private func split() -> (FilterRow?, [FilterRow]) {
        let cat = vm.panel.first(where: { $0.name.contains("类别") || $0.name.contains("频道") }) ?? vm.panel.first
        return (cat, vm.panel.filter { $0.key != cat?.key })
    }

    var body: some View {
        let parts = split()
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                // v1.10.70 每行钉组名 + 打头"全部XX"兜底胶囊(照用户甩的竞品图)
                if let cat = parts.0, !cat.options.isEmpty {
                    FilterRowLine(vm: vm, row: cat)
                        .padding(.top, 6)
                }
                ForEach(parts.1.filter { !$0.options.isEmpty }, id: \.key) { row in
                    FilterRowLine(vm: vm, row: row)
                }
                if !vm.note.isEmpty {
                    Text(vm.note).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if vm.rows.isEmpty && vm.busy {
                    GridSkeleton().padding(.horizontal, 8)
                }
                Grid2Cards(rows: vm.rows)
                    .padding(.horizontal, 8)
                // 翻页走手动(v59 铁律)
                MoreButton(busy: vm.busy, more: { vm.more() })
                    .padding(.bottom, 12)
            }
            .padding(.vertical, 6)
        }
        .task { vm.loadPanel() }
    }
}

// v1.10.70 筛选行: 组名钉左 + 胶囊横滑
// v1.10.72 用户终审: 自加的"全部XX"整个废除(跟服务端的中性项撞名出双份/改名),
// 原样只显红果自己的选项; 行尚无选择时其打头"全部"项自动亮橙顶位
private struct FilterRowLine: View {
    @ObservedObject var vm: CatVM
    let row: FilterRow
    var body: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 56, alignment: .leading)
                .padding(.leading, 12)
            ChipScroller(labels: Array(row.options.enumerated()).map { i, o in
                let on = vm.picks[row.key] == o.value
                    || (vm.picks[row.key] == nil && i == 0
                        && (o.name.hasPrefix("全部") || o.name.hasPrefix("不限")))
                return (o.name, on)
            }, onPick: { vm.pick(key: row.key, value: row.options[$0].value) })
        }
    }
}

// MARK: - 上新段

private struct NewTab: View {
    @ObservedObject var vm: NewVM
    var body: some View {
        VStack(spacing: 8) {
            if !vm.dates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.dates, id: \.self) { d in
                            Button { vm.load(date: d) } label: {
                                Text(hgDay(d, today: hgToday()))
                                    .font(.footnote.weight(d == vm.date ? .bold : .regular))
                                    .padding(.horizontal, 13).padding(.vertical, 7)
                                    .background(Capsule().fill(d == vm.date ? Color.orange : Color.gray.opacity(0.15)))
                                    .foregroundStyle(d == vm.date ? .white : .primary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 6)
            }
            List {
                if !vm.note.isEmpty { Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) } }
                let online = vm.items.filter(\.online)
                let later = vm.items.filter { !$0.online }
                if !later.isEmpty {
                    Section {
                        HRail(title: "🗓 即将上线", sub: "先囤预告, 到点开抢",
                              items: later.map {
                                  HRail.CardLike(sid: $0.seriesId, title: $0.title,
                                                 sub: $0.note.isEmpty ? $0.publishAt : $0.note,
                                                 cover: $0.coverUrl, rank: 0)
                              })
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                if vm.items.isEmpty && vm.busy {
                    Section {
                        GridSkeleton().listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                if !online.isEmpty {
                    Section {
                        Grid2Lite(items: online.map {
                            var sub = "全\($0.episodeCount)集"
                            if !$0.categories.isEmpty { sub += " · " + $0.categories.joined(separator: "·") }
                            if !$0.heat.isEmpty { sub = $0.heat + " · " + sub }
                            return HRail.CardLike(sid: $0.seriesId, title: $0.title,
                                                  sub: sub, cover: $0.coverUrl, rank: 0)
                        }, nearEnd: { i in
                            if i >= online.count - 9 { vm.more() }
                        })
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        MoreButton(busy: vm.busy, more: { vm.more() })
                    } header: {
                        Text("已上线 · 点卡整剧下载").font(.system(size: 16, weight: .heavy))
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { vm.load() }
        }
    }
}

// MARK: - 分类段

private struct CatTab: View {
    @ObservedObject var vm: CatVM
    var body: some View {
        VStack(spacing: 6) {
            ForEach(vm.panel, id: \.key) { row in
                if !row.options.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                        ChipScroller(labels: row.options.map { ($0.name, vm.picks[row.key] == $0.value) },
                                     onPick: { vm.pick(key: row.key, value: row.options[$0].value) })
                    }
                    .padding(.top, 2)
                }
            }
            List {
                if !vm.note.isEmpty { Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) } }
                if vm.rows.isEmpty && vm.busy {
                    Section {
                        GridSkeleton().listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                Section {
                    Grid2Cards(rows: vm.rows, nearEnd: { i in
                        if i >= vm.rows.count - 3 { vm.more() }
                    })
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("筛选结果 · 条件随便松紧").font(.system(size: 16, weight: .heavy))
                }
            }
            .listStyle(.plain)
            .overlay { if vm.busy && vm.rows.isEmpty { ProgressView().controlSize(.large) } }
        }
    }
}

// MARK: - 演员段

private struct CastRowView: View {
    let it: RankItem
    var body: some View {
        HStack(spacing: 10) {
            Text("\(it.position)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(it.position <= 3 ? Color.orange : .secondary)
                .frame(width: 26)
                    AsyncImage(url: URL(string: hgImgURL(it.avatarUrl.isEmpty ? it.coverUrl : it.avatarUrl))) {
                $0.resizable().scaledToFill()
            } placeholder: { Color.gray.opacity(0.15) }
                .frame(width: 56, height: 56)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(it.actor).font(.subheadline).lineLimit(1)
                let sub = it.details.isEmpty ? it.score : (it.score + " · " + it.details.joined(separator: " "))
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

func podRing(_ place: Int) -> Color {
    switch place {
    case 1: return Color(red: 0.95, green: 0.68, blue: 0.13)
    case 2: return Color(white: 0.62)
    default: return Color(red: 0.76, green: 0.47, blue: 0.27)
    }
}

private struct CastTab: View {
    @EnvironmentObject private var nav: TheaterNav
    @ObservedObject var vm: CastVM
    var body: some View {
        List {
            if !vm.note.isEmpty { Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) } }
            let top = Array(vm.items.prefix(3))
            let rest = Array(vm.items.dropFirst(3))
            if !top.isEmpty {
                Section {
                    HStack(spacing: 0) {
                        ForEach(Array(top.enumerated()), id: \.offset) { i, it in
                            Button { nav.go(HgActorGo(uid: it.userId, name: it.actor), "podium " + it.actor) } label: {
                                CastPodium(it: it, place: i + 1)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 10)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            if !rest.isEmpty {
                Section {
                    ForEach(Array(rest.enumerated()), id: \.offset) { i, it in
                        if it.userId.isEmpty {
                            CastRowView(it: it)
                        } else {
                            Button { nav.go(HgActorGo(uid: it.userId, name: it.actor), "castrow " + it.actor) } label: {
                                CastRowView(it: it)
                            }
                            .buttonStyle(.plain)
                            .onAppear { if i >= rest.count - 6 { vm.more() } }
                        }
                    }
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("人气榜 · 点进去看 TA 演过啥").font(.system(size: 16, weight: .heavy))
                }
            }
        }
        .listStyle(.plain)
        .overlay { if vm.busy && vm.items.isEmpty { ProgressView().controlSize(.large) } }
        .refreshable { vm.load() }
    }
}

// 前三名领奖台(金银铜描边圆头像)
private struct CastPodium: View {
    let it: RankItem
    let place: Int
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: 84, height: 84)
                    .overlay {
                                AsyncImage(url: URL(string: hgImgURL(it.avatarUrl.isEmpty ? it.coverUrl : it.avatarUrl))) {
                            $0.resizable().scaledToFill()
                        } placeholder: { Color.gray.opacity(0.16) }
                    }
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(podRing(place), lineWidth: 3)
                    }
                RankBadge2(rank: place).offset(y: 8)
            }
            .padding(.top, 6)
            Text(it.actor)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .padding(.top, 6)
            Text(it.score)
                .font(.caption2).foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
    }
}

struct ActorPage: View {
    let uid: String
    let name: String
    @StateObject private var vm = ActorWorksVM()

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: hgImgURL(vm.p?.avatarUrl ?? ""))) { $0.resizable().scaledToFill() }
                        placeholder: { Color.gray.opacity(0.15) }
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.headline)
                        let tagline = ((vm.p?.tags ?? []) + (vm.p?.labels ?? [])).joined(separator: " · ")
                        if !tagline.isEmpty {
                            Text(tagline).font(.caption).foregroundStyle(.secondary)
                        }
                        let stats = fmtStats()
                        if !stats.isEmpty {
                            Text(stats).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            Section {
                if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundStyle(.secondary) }
                if !vm.works.isEmpty {
                    Grid2Lite(items: vm.works.map { w in
                        var sub = ""
                        if w.heat > 0 { sub = hgWan(w.heat) + "热度" }
                        if !w.tags.isEmpty { sub += (sub.isEmpty ? "" : " · ") + w.tags.joined(separator: "·") }
                        return HRail.CardLike(sid: w.seriesId, title: w.title,
                                              sub: sub, cover: w.coverUrl, rank: 0)
                    }, nearEnd: { i in
                        if i >= vm.works.count - 9 { vm.more() }
                    })
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                MoreButton(busy: vm.busy, more: { vm.more() })
            } header: {
                Text("TA的作品 · 点海报整剧下载").font(.system(size: 16, weight: .heavy))
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.load(uid) }
    }

    private func fmtStats() -> String {
        guard let p = vm.p, p.followers > 0 || p.likes > 0 else { return "" }
        var out = ""
        if p.followers > 0 { out += "粉丝 " + wan(p.followers) }
        if p.likes > 0 { out += (out.isEmpty ? "" : " · ") + "获赞 " + wan(p.likes) }
        return out
    }
    private func wan(_ n: Int) -> String {
        n >= 10_000 ? "\((n + 5_000) / 10_000)万" : "\(n)"
    }
    private func workSub(_ w: Work) -> String {
        var sub = w.tags.joined(separator: "·")
        if w.heat > 0 { sub += (sub.isEmpty ? "" : " · ") + wan(w.heat) + "热度" }
        return sub
    }
}

struct ActorResolveView: View {
    let name: String
    @State private var uid = ""
    @State private var done = false

    var body: some View {
        Group {
            if !uid.isEmpty {
                ActorPage(uid: uid, name: name)
            } else if done {
                ContentUnavailableView {
                    Label("人气榜里没找到「\(name)」", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("演员桥只认人气榜头部约75位；想看 TA 的剧可以去发现段搜剧名")
                }
            } else {
                ProgressView("在演员榜里找 ta…")
                    .task {
                        uid = await ActorVM.lookup(name)
                        done = true
                    }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 详情(v1.10.36 P0 大改版: 学 iDuanJu 排版, 下载器定位)
// 模糊海报 hero + 数据卡(官网第二腿) + 标签胶囊 + 折叠简介 + 下载主行
// + 选集分卷六列网格(点选=直发下载选中集) + 演员圆头像 rail(官网带头像)

struct TheaterDetailView: View {
    let want: HgWant
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: TheaterNav
    @Environment(\.dismiss) private var dismiss
    @State private var s: Openhongguo.Series?
    @State private var busy = false
    @State private var web: HgWebDetail?
    @State private var eps: [Episode] = []
    @State private var sel: Set<Int> = []
    @State private var vol = 0
    @State private var introOpen = false

    var body: some View {
        Group {
            if let sv = s {
                detailBody(sv)
            } else if busy {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("取详情中… 稍等一两秒")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                GonePage(want: want) {
                    busy = true
                    Task {
                        guard let c = Hongguo.client else { busy = false; return }
                        s = try? await c.getSeries(want.sid)
                        busy = false
                    }
                }
            }
        }
        .navigationTitle("剧场详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            busy = true
            defer { busy = false }
            guard let c = Hongguo.client else { return }
            // 目录口不吃风控, 直连快进快出(旧四段退避让假号页干转 8 秒)
            s = try? await c.getSeries(want.sid)
            HGTrail.note("hgdetail sid=\(want.sid) ok=\(s != nil)")
            guard s != nil else { return }
            Task {
                // 集表: 选集网格用(目录口, 免闸)
                eps = (try? await Hongguo.episodes(want.sid)) ?? []
                HGTrail.note("hgdetail eps=\(eps.count)")
            }
            Task {
                // 官网第二腿: 收藏数/评分/热度/标签/演员头像, 挂了就无感
                web = await HgWeb.detail(want.sid)
            }
        }
    }

    private func detailBody(_ sv: Openhongguo.Series) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero(sv)
                statsRow
                tagChips(sv)
                introBlock(sv.description)
                actionRow(sv)
                episodesBlock
                castBlock(sv)
            }
            .padding(.bottom, 26)
        }
    }

    // 300pt 模糊海报 hero: 一张图两用, 零成本高级感
    private func hero(_ sv: Openhongguo.Series) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: sv.coverUrl)) { $0.resizable().scaledToFill() }
                placeholder: { Color.gray.opacity(0.25) }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipped()
                .blur(radius: 30).saturation(1.15)
            LinearGradient(colors: [Color.black.opacity(0.15), Color.black.opacity(0.05),
                                    Color.black.opacity(0.55), Color.black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 14) {
                AsyncImage(url: URL(string: sv.coverUrl)) { $0.resizable().scaledToFill() }
                    placeholder: { Color.gray.opacity(0.3) }
                    .frame(width: 116, height: 155)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if sv.episodeCount > 0 {
                            Text("全\(sv.episodeCount)集")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.7), radius: 2)
                                .padding(7)
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 15, y: 14)
                VStack(alignment: .leading, spacing: 6) {
                    Text("红果短剧")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange))
                    Text(sv.title)
                        .font(.system(size: 23, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    Text(Self.heroMeta(sv))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(height: 300)
    }

    static func heroMeta(_ sv: Openhongguo.Series) -> String {
        var out = sv.episodeCount > 0 ? "全 \(sv.episodeCount) 集" : "短剧"
        if !sv.author.isEmpty { out += " · " + sv.author }
        if !sv.category.isEmpty { out += " · " + sv.category }
        return out
    }

    // 数据卡: 收藏/评分/热度, 缺项就少一格, 绝不硬凑(iDuanJu 收缩原则)
    @ViewBuilder private var statsRow: some View {
        let cells = statsCells()
        if !cells.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                    if i > 0 {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 34)
                    }
                    VStack(spacing: 4) {
                        Text(cell.0).font(.system(size: 17, weight: .bold)).monospacedDigit()
                        Text(cell.1).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground)))
            .padding(.horizontal, 16)
        }
    }

    static func fmtCnt(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 1e8) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 1e4) }
        return "\(n)"
    }

    private func statsCells() -> [(String, String)] {
        var out: [(String, String)] = []
        if let w = web {
            if w.favorite > 0 { out.append((TheaterDetailView.fmtCnt(w.favorite), "收藏")) }
            if !w.rating.isEmpty { out.append((w.rating, w.ratingCount > 0 ? "评分·\(TheaterDetailView.fmtCnt(w.ratingCount))人" : "评分")) }
            if !w.hotText.isEmpty { out.append((w.hotText, "全网热度")) }
        }
        if out.isEmpty, let sv = s, sv.heat > 0 {
            out.append((hgWan(sv.heat), "热度"))
        }
        return Array(out.prefix(3))
    }

    @ViewBuilder private func tagChips(_ sv: Openhongguo.Series) -> some View {
        let tags = (web?.tags ?? []).isEmpty
            ? sv.category.split(separator: " ").map(String.init)
            : (web?.tags ?? [])
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags.prefix(10), id: \.self) { t in
                        Text(t).font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder private func introBlock(_ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.callout)
                    .lineSpacing(4)
                    .lineLimit(introOpen ? nil : 2)
                    .textSelection(.enabled)
                if text.count > 55 {
                    Button(introOpen ? "收起" : "展开") {
                        withAnimation(.easeOut(duration: 0.2)) { introOpen.toggle() }
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func actionRow(_ sv: Openhongguo.Series) -> some View {
        VStack(spacing: 8) {
            Button {
                app.hgWant = want
                app.selection = .pick
                dismiss()
            } label: {
                Label("整剧下载 \(sv.episodeCount > 0 ? "· 全\(sv.episodeCount)集" : "") · 1080P",
                      systemImage: "arrow.down.circle")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color.orange))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            if !sel.isEmpty {
                Button {
                    app.hgWant = HgWant(sid: want.sid, title: want.title, eps: sel.sorted())
                    app.selection = .pick
                    dismiss()
                } label: {
                    Text("下载选中 \(sel.count) 集 · 1080P")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            }
            Text("送回拾页自动发车；档案+弹幕一并领回。一部大致 1GB 上下，建议 Wi-Fi。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    // 选集: 分卷 chips + 六列数字格, 点=勾选, 勾了就出"下载选中"
    @ViewBuilder private var episodesBlock: some View {
        if !eps.isEmpty {
            let groups = TheaterDetailView.groupVolumes(eps.map(\.number))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("选集").font(.system(size: 17, weight: .bold))
                    Text("共 \(eps.count) 集 · 点数字挑着下").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !sel.isEmpty {
                        Button("清空") { sel.removeAll() }.font(.footnote)
                    }
                }
                if groups.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                                Button { vol = i } label: {
                                    Text("\(g.first ?? 1)-\(g.last ?? 0)")
                                        .font(.footnote.weight(vol == i ? .bold : .regular))
                                        .monospacedDigit()
                                        .padding(.horizontal, 13).padding(.vertical, 7)
                                        .background(Capsule().fill(vol == i ? Color.orange : Color.primary.opacity(0.07)))
                                        .foregroundStyle(vol == i ? .white : .primary)
                                }
                            }
                        }
                    }
                }
                let shown = groups[min(vol, max(0, groups.count - 1))]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                          spacing: 8) {
                    ForEach(shown, id: \.self) { n in
                        Button {
                            if sel.contains(n) { sel.remove(n) } else { sel.insert(n) }
                        } label: {
                            Text("\(n)")
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(sel.contains(n) ? Color.orange.opacity(0.18)
                                                          : Color(uiColor: .secondarySystemBackground)))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(sel.contains(n) ? Color.orange : Color.clear,
                                                  lineWidth: 1.3))
                        }
                        .buttonStyle(.plain)
                    }
                }
                // 全选本页 + 一键选整卷的快捷
                HStack(spacing: 14) {
                    Button("全选本页") { sel.formUnion(shown) }.font(.footnote)
                    Button("反选本页") {
                        for n in shown { if sel.contains(n) { sel.remove(n) } else { sel.insert(n) } }
                    }.font(.footnote)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
        }
    }

    static func groupVolumes(_ nums: [Int]) -> [[Int]] {
        let sorted = nums.sorted()
        guard sorted.count > 30 else { return sorted.isEmpty ? [] : [sorted] }
        let size = sorted.count > 600 ? 60 : (sorted.count > 300 ? 50 : 30)
        var out: [[Int]] = []
        var i = 0
        while i < sorted.count {
            out.append(Array(sorted[i..<min(i + size, sorted.count)]))
            i += size
        }
        return out
    }

    @ViewBuilder private func castBlock(_ sv: Openhongguo.Series) -> some View {
        if let c = web?.celebrities, !c.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("演员").font(.system(size: 17, weight: .bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(c, id: \.name) { ce in
                            Button { nav.go(HgActor(name: ce.name), "cast " + ce.name) } label: {
                                VStack(spacing: 5) {
                                    Color.clear
                                        .frame(width: 56, height: 56)
                                        .overlay {
                                            if ce.avatar.isEmpty {
                                                LinearGradient(colors: [Color.orange.opacity(0.7), Color.pink.opacity(0.7)],
                                                               startPoint: .top, endPoint: .bottom)
                                                Text(String(ce.name.prefix(1)))
                                                    .font(.system(size: 20, weight: .bold))
                                                    .foregroundStyle(.white)
                                            } else {
                                                AsyncImage(url: URL(string: hgImgURL(ce.avatar))) {
                                                    $0.resizable().scaledToFill()
                                                } placeholder: { Color.gray.opacity(0.2) }
                                            }
                                        }
                                        .clipShape(Circle())
                                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
                                    Text(ce.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    if !ce.role.isEmpty {
                                        Text(ce.role).font(.system(size: 10))
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(width: 64)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        } else {
            castChips(sv)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func castChips(_ sv: Openhongguo.Series) -> some View {
        let raw = sv.rows.first(where: { $0.kind == InfoKind.twoActors })?.text ?? ""
        if raw.contains("演员·") {
            let names = parseNames(raw)
            if !names.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("演员").font(.caption).foregroundStyle(.secondary)
                        ForEach(names, id: \.self) { n in
                            Button { nav.go(HgActor(name: n), "chip " + n) } label: {
                                Text(n).font(.footnote)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 2)
            }
        }
    }

    private func parseNames(_ raw: String) -> [String] {
        var s = raw
        if let r = s.range(of: "演员·") { s.removeSubrange(r.lowerBound..<r.upperBound) }
        return s.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0 == "、" || $0 == "," })
            .map(String.init)
    }
}

// 红果没有该剧(多为搜索把演员包成的假剧目) 的明路页
private struct GonePage: View {
    let want: HgWant
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            Text("红果没有《\(want.title)》")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)
            Text("可能是演员名字、或这部剧已下架。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 10) {
                Button {
                    nav.go(HgActor(name: want.title), "gone→actor")
                } label: {
                    Text("看看演员「\(want.title)」")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.orange))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button("再试一次", action: retry)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 20)
    }
    @EnvironmentObject private var nav: TheaterNav
}
