import SwiftUI
import UIKit
import Openhongguo   // v1.10.90 认档弹窗要用 SeriesSummary

// MARK: - v1.10.85 多季归册(用户点单): "云渺 / 云渺2 / 云渺·第二季" 这类同名多册
// 在剧墙归成一张册卡, 点开分季挑。纯本地名字分组, 不联网不碰库结构。

struct ShelfGroup: Identifiable, Hashable {
    let id: String              // 册基名(标点空格已抹平的分组键)
    let title: String           // 给人看的名字(取首册剥号后的原形)
    let vols: [Series]          // 已按季号升序
    var isPack: Bool { vols.count > 1 }
    var cover: URL? { vols.first?.cover }
    var epTotal: Int { vols.reduce(0) { $0 + $1.count } }
}

enum DramaShelf {
    // v1.10.86 真机定案: 红果多季真名是"云渺1：我修仙多年强亿点怎么了"数字在**中间带冒号**,
    // 只剥尾巴永远合不上 → 加规则0 从名字里第一个数字块就地切主标题
    static let seps: Set<Character> = ["：", ":", "-", "－", "—", "·"]
    static let zhDigits: Set<Character> = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "两"]

    private static func cutPre(_ chars: [Character], _ i: Int) -> String? {
        var pre = String(chars[0..<i]).trimmingCharacters(in: trimSet)
        while pre.hasSuffix("第") {
            pre = String(pre.dropLast()).trimmingCharacters(in: trimSet)
        }
        return pre.count >= 2 ? pre : nil
    }

    static func midBase(_ name: String) -> String? {
        let chars = Array(name)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isASCII, c.isNumber {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                if j < chars.count, seps.contains(chars[j]) || chars[j] == "季" || chars[j] == "部" {
                    return cutPre(chars, i)
                }
                return nil   // "18岁那年": 数字后是字不是分隔符, 只判第一个数字块
            }
            if zhDigits.contains(c), i + 1 < chars.count, chars[i + 1] == "季" || chars[i + 1] == "部" {
                return cutPre(chars, i)
            }
            i += 1
        }
        return nil
    }

    // 尾巴季号剥离: "第N季/部"、"-N"、" N"、裸"N"、"Season N"、汉字季
    // 对拍(shelf_test.py)补三刀: 裸尾数\d{1,3}也剥(红果第二季官方名就叫"云渺2")、
    // 切完的尾巴把 ·－—_ 等连接符一并 trim、光杆"二季"也能剥
    static let trimSet = CharacterSet(charactersIn: " \t\u{3000}-－—_·")

    static func base(_ name: String) -> String {
        if let m = midBase(name) { return m }
        var n = name.trimmingCharacters(in: trimSet)
        let zh = "[一二三四五六七八九十两]"
        var guard0 = 0
        while n.count > 2, guard0 < 6 {
            guard0 += 1
            var changed = false
            for pat in ["第\\s*\\d+\\s*[季部]$", "\\s*[季部]\\s*\\d+$",
                        "\\s*[\\-－—_·]\\s*\\d{1,3}$", "\\s+\\d{1,3}$",
                        "(?i)\\s*season\\s*\\d+$",
                        "第\\s*\(zh)\\s*[季部]$", "\\s*[季部]\(zh)$",
                        "\(zh)[季部]$", "\\d{1,3}$"] {
                if let r = n.range(of: pat, options: [.regularExpression, .caseInsensitive]) {
                    let cut = String(n[n.startIndex..<r.lowerBound])
                        .trimmingCharacters(in: trimSet)
                    if cut.count >= 2 { n = cut; changed = true }
                    break
                }
            }
            if !changed { break }
        }
        return n.isEmpty ? name : n
    }

    // 季号(排序用): 先就地找"数字块+冒号/季部"(云渺1：xxx), 再退尾巴老规矩, 取不到=0
    static func seasonNo(_ name: String) -> Int {
        let chars = Array(name)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isASCII, c.isNumber {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                if j < chars.count, seps.contains(chars[j]) || chars[j] == "季" || chars[j] == "部" {
                    return Int(String(chars[i..<j])) ?? 0
                }
                if j == chars.count, i > 0 { return Int(String(chars[i..<j])) ?? 0 }
                break
            }
            i += 1
        }
        let zhMap = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                     "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "两": 2]
        if let r = name.range(of: "(第\\s*(\\d+)\\s*[季部]|(\\d+)\\s*[季部]|season\\s*(\\d+))$",
                              options: [.regularExpression, .caseInsensitive]) {
            let digits = name[r].filter { $0.isNumber }
            return Int(digits) ?? 0
        }
        for (ch, v) in zhMap {
            if name.range(of: "第\\s*" + ch + "\\s*[季部]", options: .regularExpression) != nil { return v }
            if name.range(of: "[\\-－—_·\\s]" + ch + "\\s*[季部]", options: .regularExpression) != nil { return v }
        }
        if let r = name.range(of: "[\\-－—_·\\s](\\d{1,3})$", options: .regularExpression) {
            let digits = name[r].filter { $0.isNumber }
            return Int(digits) ?? 0
        }
        if let r = name.range(of: "(?<=[^0-9])\\d{1,3}$", options: .regularExpression),
           name.count > 3 {
            return Int(name[r]) ?? 0
        }
        return 0
    }

    // v1.10.88 归册金标准: 剧档案里的官方 relatedAlbumId 为主键(乡下真千金那种
    // 换名续季自动合、同名不同剧本的不会乱合); 档案没拉过的老剧退名字规则
    static func meta(_ s: Series) -> SeriesMeta? {
        if let hit = memo[s.id] { return hit }
        let m = SeriesMetaStore.load(s.url)
        memo[s.id] = m
        return m
    }
    private static var memo: [String: SeriesMeta?] = [:]

    static func seasonOf(_ s: Series) -> Int {
        meta(s)?.seasonIdx ?? seasonNo(s.name)
    }

    static func group(_ list: [Series]) -> [ShelfGroup] {
        memo = [:]
        var dict: [String: [Series]] = [:]
        var titles: [String: String] = [:]
        for s in list {
            let m = meta(s)
            let key: String
            if let m, m.solo {
                key = "S:" + s.id                                // v1.10.90 人工钦定单剧, 天王老子来了也不进册
            } else if let m, !m.albumId.isEmpty, albumTrust(m, s) {
                key = "A:" + m.albumId                          // v89 只信验明正身的官方合集
            } else if let m, m.albumFetched {
                if m.svrTitle == SeriesMeta.noMatch {
                    // 红果查无此剧(多半抖音版): 回名字规则, 有季号才攀队
                    let n = seasonNo(s.name)
                    key = n > 0 ? "N:" + norm(base(s.name)) : "B:" + s.id
                } else {
                    key = "S:" + s.id                            // 官方认证单季, 别再按名字硬凑
                }
            } else {
                // v1.10.89 无档案兜底也要看牌: 只有名字里带季号才算续集意图;
                // 光杆"云渺"绝不单枪匹马攀"云渺1：xxx"的队(用户点破的冤案)
                let n = seasonNo(s.name)
                key = n > 0 ? "N:" + norm(base(s.name)) : "B:" + s.id
            }
            dict[key, default: []].append(s)
            let b = base(s.name)
            let cur = titles[key]
            if cur == nil || (b.count < (cur ?? "zzzz").count && b.count >= 2) { titles[key] = b }
        }
        return dict.map { k, v in
            // 单册显示原名(剥号只给多季册用, 免得"云渺3：镇魔世家"被剥成光"云渺"误会)
            let t = v.count == 1 ? v[0].name : (titles[k] ?? k)
            return ShelfGroup(id: k, title: t, vols: v.sorted { a, b in
                let sa = seasonOf(a), sb = seasonOf(b)
                if sa != sb { return sa < sb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
        }.sorted { g1, g2 in
            // 册(多季)优先沉后按集数, 单册按更新时间感(名字序) — 与剧墙原排序气质一致
            if g1.isPack != g2.isPack { return !g1.isPack }
            return g1.title.localizedStandardCompare(g2.title) == .orderedAscending
        }
    }

    // 档案的 album 是否配得上这个文件夹: svrTitle 剥号后须与文件夹名同源
    private static func albumTrust(_ m: SeriesMeta, _ s: Series) -> Bool {
        if m.svrTitle.isEmpty { return true }            // 老档案没换证, 暂且信(补档一轮后全换新)
        if m.svrTitle == SeriesMeta.noMatch { return false }
        return norm(base(m.svrTitle)) == norm(base(s.name))
    }

    // 只留字母数字(CJK 也算 alphanumeric) — 逗号空格标点全抹
    static func norm(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}

// 剧墙: 单册=原卡直接进, 长按单卡可"重新认档/清空档案"; 多季册=一张卡挂"N季"徽, 点开分季清单
// destination 由 callers 供给(短剧=DramaEpisodes / 私盒=PrivateEpisodes)
struct ShelfGrid<Destination: View>: View {
    let source: [Series]
    let destination: (Series) -> Destination
    @State private var openPack: ShelfGroup?
    @State private var rebind: Series?
    @State private var bump = 0
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        // bump 踢一下即全量重分组(认档/清档后立改墙, memo 每次自清)
        let groups = bump >= 0 ? DramaShelf.group(source) : []
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(groups) { g in
                    if g.isPack {
                        Button { openPack = g } label: { cell(g.title, g.cover, "\(g.vols.count)季·\(g.epTotal)集", pack: true) }
                            .buttonStyle(.plain)
                    } else if let s = g.vols.first {
                        NavigationLink(value: s) { cell(s.name, s.cover, "\(s.count)集", pack: false) }
                            .buttonStyle(.plain)
                            // v1.10.90 人工认档钥匙: 红果改名上架的剧(云渺→云渺第一季)自动认不到, 长按你来点名
                            .contextMenu {
                                Button { rebind = s } label: { Label("重新认档", systemImage: "text.magnifyingglass") }
                                Button(role: .destructive) { clearMeta(s) } label: { Label("清空档案撤假海报", systemImage: "trash") }
                            }
                    }
                }
            }
            .padding(10)
        }
        .sheet(item: $openPack) { g in
            NavigationStack {
                List {
                    ForEach(g.vols) { s in
                        NavigationLink(value: s) {
                            HStack(spacing: 10) {
                                Color.clear.frame(width: 44, height: 62)
                                    .overlay {
                                        Group {
                                            if let c = s.cover { Thumb(url: c) }
                                        }
                                        .clipped()
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.name).font(.body.weight(.medium))
                                    // v1.10.88 官方季号徽章: 第N季一眼分明
                                    let sn = DramaShelf.seasonOf(s)
                                    HStack(spacing: 6) {
                                        Text("\(s.count) 集").font(.caption).foregroundStyle(.secondary)
                                        if sn > 0 {
                                            Text("第\(sn)季")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(g.title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Series.self) { s in destination(s) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $rebind) { s in
            RebindSheet(s: s) { bump += 1 }
        }
    }

    private func clearMeta(_ s: Series) {
        let fm = FileManager.default
        try? fm.removeItem(at: SeriesMetaStore.file(s.url))
        try? fm.removeItem(at: s.url.appendingPathComponent("封面.jpg"))
        HGTrail.note("shelf clearmeta " + s.name)
        bump += 1
    }

    private func cell(_ name: String, _ cover: URL?, _ badge: String, pack: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(0.667, contentMode: .fit)
                .overlay {
                    Group {
                        if let c = cover { Thumb(url: c) } else { Color(white: 0.15) }
                    }
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text(badge)
                        .font(.caption2.weight(pack ? .bold : .regular))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(pack ? Color.orange.opacity(0.9) : .black.opacity(0.55)))
                        .padding(4)
                }
            Text(name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - v1.10.90 人工认档: 长按单卡 → 搜红果 → 点谁就是谁(改名上架/马甲名唯一解)
private struct RebindSheet: View {
    let s: Series
    let onDone: () -> Void
    @Environment(\.dismiss) private var dis
    @State private var q: String
    @State private var rows: [SeriesSummary] = []
    @State private var busy = false
    @State private var note = ""
    @State private var solo = false

    init(s: Series, onDone: @escaping () -> Void) {
        self.s = s
        self.onDone = onDone
        _q = State(initialValue: s.name)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Toggle(isOn: $solo) {
                    Text("钦定单剧 · 谁也别想把它塞进合集").font(.footnote)
                }
                .tint(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                if busy && rows.isEmpty {
                    Spacer()
                    ProgressView().controlSize(.large)
                    Text("正去红果打听…").font(.footnote).foregroundStyle(.secondary).padding(6)
                    Spacer()
                } else if rows.isEmpty {
                    Spacer()
                    Text(note.isEmpty ? "红果没有同名剧 — 换个词搜搜(比如主演名字)" : note)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                    Spacer()
                } else {
                    List(rows, id: \.id) { r in
                        Button { bind(r.id, r.title) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.title).font(.body.weight(.medium))
                                Text("\(r.episodeCount) 集").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
                if !note.isEmpty && !rows.isEmpty {
                    Text(note).font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity).padding(6)
                }
            }
            .navigationTitle("给「\(s.name)」认档")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always))
            .onSubmit(of: .search) { go() }
            .task { if rows.isEmpty && !busy { go() } }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完事") { dis(); onDone() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func go() {
        busy = true
        rows = []
        note = ""
        Task {
            guard let c = Hongguo.client else {
                busy = false; note = "红果引擎未就绪"; return
            }
            let r = try? await Hongguo.attempt(c, { try await c.search(q) })
            rows = (r?.items ?? []).filter { $0.episodeCount > 0 }
            if rows.isEmpty { note = "「\(q)」红果没搜到, 换个词(试试主演名)" }
            busy = false
        }
    }

    private func bind(_ sid: String, _ title: String) {
        guard !busy else { return }
        busy = true
        note = "认档中…"
        Task {
            guard let c = Hongguo.client else {
                busy = false; note = "红果引擎未就绪"; return
            }
            await SeriesMetaStore.harvest(c, sid: sid, title: s.name, dir: s.url)
            if var m = SeriesMetaStore.load(s.url) {
                m.solo = solo
                try? JSONEncoder().encode(m).write(to: SeriesMetaStore.file(s.url))
            }
            HGTrail.note("shelf rebind \(s.name) -> \(title) solo=\(solo)")
            busy = false
            note = "已认档：\(title)"
        }
    }
}
