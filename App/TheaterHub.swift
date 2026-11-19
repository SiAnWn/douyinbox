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

func hgCoverUrl(sid: String, _ url: String) -> String {
    if !url.isEmpty { return url }
    return CoverBank.data[sid] ?? ""
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
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
                if let sr = try? await Hongguo.attempt(c, {
                    try await c.shortRank(ShortRankQuery(board: board))
                }) {
                    var out: [HRail.CardLike] = []
                    for it in sr.items.prefix(10) where !it.seriesId.isEmpty {
                        out.append(HRail.CardLike(sid: it.seriesId, title: it.title,
                                                 sub: it.score, cover: it.coverUrl, rank: it.position))
                    }
                    set(self, out)
                }
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
    private var cursor: String?

    func load() {
        cursor = nil
        fetch(reset: true)
    }
    func more() {
        guard cursor != nil, !busy else { return }
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
            self.cursor = sr.hasMore ? sr.cursor : nil
            if self.items.isEmpty { self.note = "榜上空空的" }
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

    func doSearch(_ q: String) {
        smode = q.trimmingCharacters(in: .whitespacesAndNewlines)
        HGTrail.note("hgsearch go '\(smode.prefix(20))'")
        guard !smode.isEmpty else { sres = []; snote = ""; return }
        rememberHist(smode)
        fetchSearch(reset: true)
    }

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
        fetchSearch(reset: false)
    }

    var searchHasMore: Bool { scur != nil }

    private func fetchSearch(reset: Bool) {
        guard !sbusy else { return }
        sbusy = true
        if reset { snote = ""; sseen = [] }
        let q = smode
        let cur = reset ? nil : scur
        Task {
            defer { sbusy = false }
            guard let c = Hongguo.client else { snote = "红果引擎未就绪"; return }
            // v1.10.39 搜索翻页根治(用户实锤"加载更多重复出现"): 旧版调 search 从不带游标,
            // 每次"加载更多"都拿回第一页; 且 pageSize 默认很小结果显不全。
            // 照 iDuanJu 姿势: 游标+页大小喂 search/tab 口, 目录口不吃风控不再套 attempt 退避。
            let opt = SearchOptions(cursor: cur, pageSize: 15)
            if let pg = try? await c.search(q, options: opt) {
                var items = pg.items
                // 防重铁闸: 服务端游标偶尔犯浑给重复行, 已见过的直接丢
                items = items.filter { sseen.insert($0.id).inserted }
                CoverBank.register(items)
                for i in items.indices where items[i].coverUrl.isEmpty {
                    if let c2 = CoverBank.data[items[i].id] { items[i].coverUrl = c2 }
                }
                if reset { self.sres = items } else { self.sres += items }
                self.scur = (pg.hasMore && !items.isEmpty) ? pg.cursor : nil
                HGTrail.note("hgsearch back '\(q.prefix(12))' n=\(items.count) more=\(pg.hasMore) total=\(self.sres.count) nocover=\(items.filter { $0.coverUrl.isEmpty }.count)")
                if self.sres.isEmpty { self.snote = "搜不到「\(q)」，换个词试试" }
                await self.fillCovers(Array(items.prefix(8)))
            } else { self.snote = "搜索口这次没搭手，再来一次" }
        }
    }
    private var sseen: Set<String> = []

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
    private let tabs = ["首页", "演员"]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // 红果首页同款页签: 加粗+橙色下划小线, 不用系统 segmented
                HStack(spacing: 0) {
                    ForEach(tabs.indices, id: \.self) { i in
                        VStack(spacing: 5) {
                            Text(tabs[i])
                                .font(.system(size: i == seg ? 17 : 15,
                                              weight: i == seg ? .heavy : .regular))
                                .foregroundStyle(i == seg ? .primary : .secondary)
                                .animation(.snappy(duration: 0.2), value: seg)
                            Capsule()
                                .fill(i == seg ? Color.orange : Color.clear)
                                .frame(width: 20, height: 3)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { seg = i }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)

                Group {
                    switch seg {
                    case 1: CastTab(vm: cast)
                    default: DiscoverTab(vm: disc, rails: rails)
                    }
                }
            }
            .navigationTitle("剧场")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        TheaterSearchTab(vm: disc)
                    } label: { Image(systemName: "magnifyingglass") }
                }
            }
            .task(id: seg) {
                switch seg {
                case 1: if cast.items.isEmpty { cast.load() }
                default:
                    if disc.rows.isEmpty { disc.load() }
                    rails.load()
                }
            }
            .theaterDestinations()
        }
        .environmentObject(nav)
        .onAppear { nav.bind = $path }
        .theaterDestinations()
    }
}

// 右上放大镜: 红果同款全页搜索(猜词+热搜榜)
// 目的地注册(iDuanJu routes() 同款): 单一 Route 枚举一份注册, 钉在栈根内容上
extension View {
    func theaterDestinations() -> some View {
        navigationDestination(for: TheaterNav.Route.self) { r in
            switch r {
            case .want(let w): TheaterDetailView(want: w)
            case .actorGo(let a): ActorPage(uid: a.uid, name: a.name)
            case .actor(let a): ActorResolveView(name: a.name)
            }
        }
    }
}

private struct TheaterSearchTab: View {
    @ObservedObject var vm: DiscoverVM
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
                ForEach(Array(vm.hotBoards.enumerated()), id: \.offset) { _, b in
                    Section(b.name) {
                        ForEach(Array(b.items.enumerated()), id: \.offset) { _, it in
                            Button {
                                q = it.title
                                vm.doSearch(it.title)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("\(it.position)")
                                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                                        .foregroundStyle(it.position <= 3 ? Color.orange : .secondary)
                                        .frame(width: 20)
                                    Text(it.title).font(.subheadline).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if !it.searchScore.isEmpty {
                                        Text(it.searchScore).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
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
            if !vm.sres.isEmpty {
                Section("搜索结果") {
                    // 搜索页绝不自动翻页(v1.10.33 用户实锤: 结果只有5张时
                    // 任何 onAppear 都触发续页, 列表当场膨胀重排, 手指按下去
                    // 详情页被布局抖动弹回=闪一下+返回连弹冤案)
                    Grid2Cards(rows: vm.sres, nearEnd: { _ in })
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    if vm.sbusy {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if vm.searchHasMore {
                        Button { vm.moreSearch() } label: {
                            Text("加载更多").font(.subheadline.weight(.medium))
                        }
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                Button { nav.go(HgWant(sid: s.id, title: s.title), "grid " + s.id) } label: {
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
                        .overlay {
                            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.7)],
                                           startPoint: .center, endPoint: .bottom)
                        }
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white).lineLimit(2)
                                Text(hgGridSub(s)).font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                Button { nav.go(HgWant(sid: c.sid, title: c.title), "lite " + c.sid) } label: {
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
                        .overlay {
                            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.7)],
                                           startPoint: .center, endPoint: .bottom)
                        }
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white).lineLimit(2)
                                Text(c.sub).font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
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
                            .background(Capsule().fill(pair.1 ? Color.accentColor.opacity(0.9) : Color.gray.opacity(0.18)))
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
        TabView(selection: $idx) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                Button { nav.go(HgWant(sid: s.id, title: s.title), "hero " + s.id) } label: {
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: URL(string: s.coverUrl)) {
                            $0.resizable().scaledToFill()
                        } placeholder: {
                            LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.72)],
                                       startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                            Text((s.category.isEmpty ? "" : s.category + " · ") +
                                 (s.episodeCount > 0 ? "全\(s.episodeCount)集" : "红果热映") + " · 点进去整剧下载")
                                .font(.caption).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(12)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .frame(height: 215)
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
                    Grid2Cards(rows: vm.rows, nearEnd: { i in
                        if i >= vm.rows.count - 3 { vm.more() }
                    })
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
    var body: some View {
        VStack(spacing: 8) {
            if !vm.contents.isEmpty {
                ChipScroller(labels: vm.contents.map { ($0.name, $0.id == vm.content || ($0.selected && vm.content.isEmpty)) },
                             onPick: { vm.load(content: vm.contents[$0].id, board: "") })
                    .padding(.top, 6)
                if let cur = vm.contents.first(where: { $0.id == vm.content || $0.selected }),
                   !cur.boards.isEmpty {
                    ChipScroller(labels: cur.boards.map { ($0.name, $0.id == vm.board || ($0.selected && vm.board.isEmpty)) },
                                 onPick: { vm.load(board: cur.boards[$0].id) })
                }
            }
            List {
                if !vm.note.isEmpty { Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) } }
                Section {
                    ForEach(Array(vm.items.enumerated()), id: \.offset) { i, it in
                        if it.seriesId.isEmpty {
                            // 演员榜行(可点) 或平台推广行: 展示为主
                            let name = it.actor.isEmpty ? it.title : it.actor
                            let sub = RankTab.actorSub(it)
                            let cover = it.coverUrl.isEmpty ? it.avatarUrl : it.coverUrl
                            HStack(spacing: 10) {
                                Text("\(it.position)")
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundStyle(it.position <= 3 ? Color.orange : .secondary)
                                    .frame(width: 26)
                                AsyncImage(url: URL(string: cover)) { $0.resizable().scaledToFill() }
                                    placeholder: { Color.gray.opacity(0.15) }
                                    .frame(width: 52, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name)
                                        .font(.subheadline).lineLimit(1)
                                    Text(sub)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        } else {
                            let pair = hgArrow(it.change)
                            Button { nav.go(HgWant(sid: it.seriesId, title: it.title), "rank " + it.seriesId) } label: {
                                HStack(spacing: 10) {
                                    Color.clear
                                        .frame(width: 52, height: 70)
                                        .overlay {
                                            AsyncImage(url: URL(string: it.coverUrl)) {
                                                $0.resizable().scaledToFill()
                                            } placeholder: { Color.gray.opacity(0.16) }
                                        }
                                        .overlay(alignment: .topLeading) {
                                            RankBadge2(rank: it.position).padding(3)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text((it.episodeCount > 0 ? "全\(it.episodeCount)集" : "短剧") +
                                             (it.score.isEmpty ? "" : " · " + it.score))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    VStack(alignment: .trailing, spacing: 6) {
                                        if let pair {
                                            Text(pair.0).font(.caption2.bold()).foregroundStyle(pair.1)
                                        }
                                        if it.promoted {
                                            Text("荐").font(.caption2.bold()).foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .onAppear { if i >= vm.items.count - 6 { vm.more() } }
                        }
                    }
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("红果榜单 · 匿名直连")
                }
            }
            .overlay { if vm.busy && vm.items.isEmpty { ProgressView().controlSize(.large) } }
            .refreshable { vm.load() }
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
            AsyncImage(url: URL(string: it.avatarUrl.isEmpty ? it.coverUrl : it.avatarUrl)) {
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
                        AsyncImage(url: URL(string: it.avatarUrl.isEmpty ? it.coverUrl : it.avatarUrl)) {
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
                    AsyncImage(url: URL(string: vm.p?.avatarUrl ?? "")) { $0.resizable().scaledToFill() }
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
                                                AsyncImage(url: URL(string: ce.avatar)) {
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
