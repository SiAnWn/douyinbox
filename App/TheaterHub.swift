import SwiftUI
import Openhongguo

// MARK: - 红果剧场 v2（v1.10.24 A菜二期）: 藏→"场" = 发现·榜单·上新·分类 四段
// 全部匿名目录接口(播放闸从未波及): shortRank 榜单(内容×榜单两级)/ newReleases 上新日历/
// shortFilterPanel+shortFilter 官方筛选墙/ hotSearch 热搜猜词 / discover+search 老两样。
// 一切剧行 → HgWant → 详情 → 一键整剧下载(送回拾页发车)。接口签名 11-18 PC 探针实锤。

struct HgWant: Hashable {
    let sid: String
    let title: String
}

// 演员导航两式: 榜上已有 uid 直落 / 简介页只有名字先查人气榜补 uid
struct HgActorGo: Hashable {
    let uid: String
    let name: String
}
struct HgActor: Hashable {
    let name: String
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
                if reset { rows = pg.items } else { rows += pg.items }
                nextCursor = pg.hasMore ? pg.cursor : nil
                if rows.isEmpty { note = isSearch ? "搜不到「\(mode)」，换个词试试" : "目录暂时空手（风控抖动，下拉再来）" }
            } else { note = "目录口这次没搭手，下拉重试" }
        }
        if guesses.isEmpty {
            Task {
                guard let c = Hongguo.client,
                      let hs = try? await Hongguo.attempt(c, { try await c.hotSearch() }) else { return }
                guesses = Array(hs.guesses.prefix(10).map(\.title))
            }
        }
    }

    func run(_ q: String) {
        mode = q.trimmingCharacters(in: .whitespacesAndNewlines)
        load()
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
            if reset { self.rows = pg.items } else { self.rows += pg.items }
            self.nextCursor = pg.hasMore ? pg.cursor : nil
            if self.rows.isEmpty { self.note = "这组合下没有剧，松一两个条件试试" }
        }
    }
}

// MARK: - 主页: 四段容器

struct TheaterHomeView: View {
    @State private var seg = 0
    @StateObject private var disc = DiscoverVM()
    @StateObject private var rank = RankVM()
    @StateObject private var news = NewVM()
    @StateObject private var cat = CatVM()
    @StateObject private var cast = CastVM()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $seg) {
                Text("发现").tag(0)
                Text("榜单").tag(1)
                Text("上新").tag(2)
                Text("分类").tag(3)
                Text("演员").tag(4)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 12)

            Group {
                switch seg {
                case 1: RankTab(vm: rank)
                case 2: NewTab(vm: news)
                case 3: CatTab(vm: cat)
                case 4: CastTab(vm: cast)
                default: DiscoverTab(vm: disc)
                }
            }
        }
        .navigationDestination(for: HgWant.self) { w in TheaterDetailView(want: w) }
        .navigationDestination(for: HgActorGo.self) { a in ActorPage(uid: a.uid, name: a.name) }
        .navigationDestination(for: HgActor.self) { a in ActorResolveView(name: a.name) }
        .task(id: seg) {
            switch seg {
            case 1: if rank.contents.isEmpty { rank.load() }
            case 2: if news.items.isEmpty { news.load() }
            case 3: cat.loadPanel()
            case 4: if cast.items.isEmpty { cast.load() }
            default: if disc.rows.isEmpty { disc.load() }
            }
        }
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
    let sid: String
    let title: String
    let sub: String
    let cover: String
    var badge: String? = nil

    var body: some View {
        NavigationLink(value: HgWant(sid: sid, title: title)) {
            HStack(spacing: 10) {
                if let b = badge {
                    Text(b)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .frame(width: 26, alignment: .center)
                        .foregroundStyle(b.count <= 2 ? Color.orange : Color.secondary)
                }
                AsyncImage(url: URL(string: cover)) { $0.resizable().scaledToFill() }
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

// MARK: - 发现段

private struct DiscoverTab: View {
    @ObservedObject var vm: DiscoverVM
    var body: some View {
        List {
            Section {
                HStack {
                    TextField("搜红果新剧 / 剧名", text: $vm.query)
                        .textFieldStyle(.plain)
                        .onSubmit { vm.run(vm.query) }
                    Button("搜索") { vm.run(vm.query) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
                .padding(.vertical, 2)
                if !vm.guesses.isEmpty {
                    FlowGuess(words: vm.guesses) { vm.run($0) }
                }
            }
            if !vm.note.isEmpty {
                Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) }
            }
            if !vm.rows.isEmpty {
                Section {
                    ForEach(vm.rows, id: \.id) { s in
                        ShowRow(sid: s.id, title: s.title,
                                sub: (s.category.isEmpty ? "" : s.category + " · ") + (s.episodeCount > 0 ? "全\(s.episodeCount)集" : "短剧"),
                                cover: s.coverUrl)
                    }
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("红果剧场 · 点进去可整剧下载")
                }
            }
        }
        .overlay { if vm.busy && vm.rows.isEmpty { ProgressView().controlSize(.large) } }
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
                    ForEach(Array(vm.items.enumerated()), id: \.offset) { _, it in
                        if it.seriesId.isEmpty {
                            // 演员榜行(v1.10.25 可点) 或平台推广行: 展示为主
                            let name = it.actor.isEmpty ? it.title : it.actor
                            var sub = ""
                            if it.actor.isEmpty {
                                sub = it.score
                            } else {
                                if !it.intro.isEmpty { sub += it.intro + " · " }
                                sub += it.score
                            }
                            if !it.details.isEmpty { sub += " · " + it.details.joined(separator: " ") }
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
                            ShowRow(sid: it.seriesId, title: it.title,
                                    sub: it.score + (it.episodeCount > 0 ? " · 全\(it.episodeCount)集" : ""),
                                    cover: it.coverUrl,
                                    badge: it.promoted ? "荐" : "\(it.position)")
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
                                Text(fmtDate(d))
                                    .font(.footnote)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(d == vm.date ? Color.accentColor.opacity(0.9) : Color.gray.opacity(0.18)))
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
                Section {
                    ForEach(Array(vm.items.enumerated()), id: \.offset) { _, nr in
                        if nr.online {
                            ShowRow(sid: nr.seriesId, title: nr.title,
                                    sub: (nr.categories.isEmpty ? "短剧" : nr.categories.joined(separator: "·")) +
                                         " · 全\(nr.episodeCount)集" + (nr.heat.isEmpty ? "" : " · " + nr.heat),
                                    cover: nr.coverUrl, badge: "新")
                        } else {
                            HStack(spacing: 10) {
                                AsyncImage(url: URL(string: nr.coverUrl)) { $0.resizable().scaledToFill() }
                                    placeholder: { Color.gray.opacity(0.15) }
                                    .frame(width: 52, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(nr.title).font(.subheadline).lineLimit(1)
                                    Text("🗓 " + (nr.note.isEmpty ? nr.publishAt : nr.note) +
                                         (nr.heat.isEmpty ? "" : " · " + nr.heat))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("红果上新日历 · 已上线可直接囤")
                }
            }
            .overlay { if vm.busy && vm.items.isEmpty { ProgressView().controlSize(.large) } }
            .refreshable { vm.load() }
        }
    }

    private func fmtDate(_ ymd: String) -> String {
        guard ymd.count == 8 else { return ymd }
        let m = ymd.dropFirst(4).prefix(2)
        let d = ymd.suffix(2)
        return "\(Int(m) ?? 0)月\(Int(d) ?? 0)日"
    }
}

// MARK: - 分类段

private struct CatTab: View {
    @ObservedObject var vm: CatVM
    var body: some View {
        VStack(spacing: 6) {
            ForEach(vm.panel, id: \.key) { row in
                if !row.options.isEmpty {
                    ChipScroller(labels: row.options.map { ($0.name, vm.picks[row.key] == $0.value) },
                                 onPick: { vm.pick(key: row.key, value: row.options[$0].value) })
                        .padding(.top, 4)
                }
            }
            List {
                if !vm.note.isEmpty { Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) } }
                Section {
                    ForEach(vm.rows, id: \.id) { s in
                        ShowRow(sid: s.id, title: s.title,
                                sub: (s.category.isEmpty ? "" : s.category + " · ") +
                                     (s.episodeCount > 0 ? "全\(s.episodeCount)集" : "短剧") +
                                     (s.author.isEmpty ? "" : " · " + s.author),
                                cover: s.coverUrl)
                    }
                    MoreButton(busy: vm.busy, more: { vm.more() })
                } header: {
                    Text("官方筛选墙 · 条件随便松紧")
                }
            }
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

private struct CastTab: View {
    @ObservedObject var vm: CastVM
    var body: some View {
        List {
            if !vm.note.isEmpty { Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) } }
            Section {
                ForEach(Array(vm.items.enumerated()), id: \.offset) { _, it in
                    if it.userId.isEmpty {
                        CastRowView(it: it)
                    } else {
                        NavigationLink(value: HgActorGo(uid: it.userId, name: it.actor)) {
                            CastRowView(it: it)
                        }
                    }
                }
                MoreButton(busy: vm.busy, more: { vm.more() })
            } header: {
                Text("演员人气榜 · 点进去看 TA 演过啥")
            }
        }
        .overlay { if vm.busy && vm.items.isEmpty { ProgressView().controlSize(.large) } }
        .refreshable { vm.load() }
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
            Section("TA的作品 · 点进去可整剧下载") {
                if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(vm.works.enumerated()), id: \.offset) { _, w in
                    NavigationLink(value: HgWant(sid: w.seriesId, title: w.title)) {
                        HStack(spacing: 10) {
                            AsyncImage(url: URL(string: w.coverUrl)) { $0.resizable().scaledToFill() }
                                placeholder: { Color.gray.opacity(0.15) }
                                .frame(width: 52, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(w.title).font(.subheadline).lineLimit(2)
                                Text(workSub(w)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
                MoreButton(busy: vm.busy, more: { vm.more() })
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

// MARK: - 详情(原有, B 菜将加演员行可点)

struct TheaterDetailView: View {
    let want: HgWant
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var s: Openhongguo.Series?
    @State private var busy = false

    var body: some View {
        List {
            if let sv = s {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: URL(string: sv.coverUrl)) { $0.resizable().scaledToFill() }
                            placeholder: { Color.gray.opacity(0.15) }
                            .frame(width: 96, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sv.title).font(.headline)
                            ForEach(rowLines(sv), id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    castChips(sv)
                }
                if !sv.description.isEmpty {
                    Section("简介") { Text(sv.description).font(.callout) }
                }
                Section {
                    Button {
                        app.hgWant = want
                        app.selection = .pick
                        dismiss()
                    } label: {
                        Label("整剧下载（红果 1080P）", systemImage: "arrow.down.circle")
                            .font(.body.weight(.bold))
                    }
                    Text("送回拾页自动发车；档案+弹幕一并领回。约 \(max(1, sv.episodeCount)) 集，一部大致 1GB 上下，建议 Wi-Fi。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(busy ? "取详情中…" : "详情加载中…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("剧场详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            busy = true
            defer { busy = false }
            guard let c = Hongguo.client else { return }
            s = try? await Hongguo.attempt(c, { try await c.getSeries(want.sid) })
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
                            NavigationLink(value: HgActor(name: n)) {
                                Text(n).font(.footnote)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
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

    private func rowLines(_ sv: Openhongguo.Series) -> [String] {
        var out: [String] = []
        for r in sv.rows {
            if r.text.isEmpty { continue }
            if r.kind == InfoKind.score || r.kind == InfoKind.category {
                out.append(r.text)
            }
        }
        if sv.episodeCount > 0 { out.append("全\(sv.episodeCount)集") }
        if sv.heat > 0 {
            out.append(sv.heat >= 10_000 ? "热度 \((sv.heat + 5_000) / 10_000)万" : "热度 \(sv.heat)")
        }
        if !sv.rightText.isEmpty { out.append(sv.rightText) }
        return out
    }
}
