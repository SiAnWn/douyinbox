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
            } else if let m, let ha = m.handAlbum, !ha.isEmpty {
                key = "A:" + ha                                  // v1.10.116 人工钦定和谁一家, 凌驾自动结论
            } else if let m, !m.albumId.isEmpty, m.svrTitle != SeriesMeta.noMatch {
                // v1.10.115 验身门拆掉(114 X光终审冤案): album 全局唯一且官方签发, 天然不会乱合;
                // 老千2/剑二十四 album 明明在手却被 svrTitle剥号比对否决 — 113 库内零假合实证此门多余
                key = "A:" + m.albumId
            } else if let m, m.albumFetched {
                // v1.10.114 X光: 有官方album却被身份证验身否决的 是头号悬案嫌疑人 单独留名
                if !m.albumId.isEmpty, m.svrTitle != SeriesMeta.noMatch {
                    HGTrail.note("shelf veto " + s.name + " album=" + m.albumId + " svr=" + m.svrTitle)
                }
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
            // v1.10.114 X光全量: 每部都报钥匙(A/N/S/B 一网打尽) 悬案不用再猜
            HGTrail.note("shelf key " + s.name + " → " + key)
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
    @State private var mergeFor: Series?      // v1.10.116 手动并册对象
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
                                // v1.10.116 手动并册: 官方通道全跑完还差临门一脚时, 你来盖章
                                Button { mergeFor = s } label: { Label("手动并入别册…", systemImage: "square.stack.3d.up.badge.plus") }
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
                        // v1.10.112 册内也能断案: 每季长按可重新认档/钦定独立(111 真机报
                        // 云渺进了册就长按无反应=认档钥匙只焊在单册卡上)
                        .contextMenu {
                            Button { rebind = s } label: { Label("重新认档", systemImage: "text.magnifyingglass") }
                            Button { mergeFor = s } label: { Label("手动并入别册…", systemImage: "square.stack.3d.up.badge.plus") }
                            Button(role: .destructive) { clearMeta(s) } label: { Label("清空档案撤假海报", systemImage: "trash") }
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
        // v1.10.116 手动并册选人册
        .sheet(item: $mergeFor) { s in
            MergeSheet(src: s, cands: source.filter { $0.id != s.id }) { o in
                mergeFor = nil
                SeriesMetaStore.applyMerge(src: s, into: o)
                bump += 1
            }
        }
        // v1.10.111 开门两连招: 先批量认亲大招(全库 sid 一把过), 再搜索兜底(无档/无 sid 的散户)
        .onAppear {
            Task { @MainActor in
                var n = await SeriesMetaStore.reunion(source)
                n += await SeriesMetaStore.autoCheck(source)
                if n > 0 { bump += 1 }
            }
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
                        Button { Task { await bind(r.id, r.title) } } label: {
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
            // v1.10.90b 红果搜索口会藏剧(《云渺》搜索就是搜不到 分享链接却是正主)
            // → 粘贴红果分享消息/链接/纯系列id 直接认档 绕过搜索
            if let sid = await linkSid(q) {
                await bind(sid, "红果分享链接", force: true)
                return
            }
            let r = try? await Hongguo.attempt(c, { try await c.search(q) })
            rows = (r?.items ?? []).filter { $0.episodeCount > 0 }
            if rows.isEmpty { note = "「\(q)」红果没搜到 — 也可能是它搜索口藏剧: 去红果App点分享把链接粘进来" }
            busy = false
        }
    }

    // 从分享消息里揪系列id: http链接(跟随302看落点query) 或用户直接粘的15位以上纯数字
    private func linkSid(_ text: String) async -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "video_series_id=(\\d{10,})", options: .regularExpression) {
            let digits = String(t[r]).filter { $0.isNumber }
            if digits.count >= 10 { return digits }
        }
        if let r = t.range(of: "\\d{15,}", options: .regularExpression),
           t.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789")).isEmpty {
            return String(t[r])
        }
        guard let u = t.range(of: "https?://\\S+", options: .regularExpression) else { return nil }
        let urlStr = String(t[u])
        guard let u2 = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: u2)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let hu = resp as? HTTPURLResponse,
              let eff = hu.url?.absoluteString else { return nil }
        if let r = eff.range(of: "video_series_id=(\\d{10,})", options: .regularExpression) {
            let digits = String(eff[r]).filter { $0.isNumber }
            if digits.count >= 10 { return digits }
        }
        return nil
    }

    private func bind(_ sid: String, _ title: String, force: Bool = false) async {
        guard force || !busy else { return }
        busy = true
        note = "认档中…"
        HGTrail.note("rebind start sid=\(sid) by=\(title)")
        guard let c = Hongguo.client else {
            busy = false; note = "红果引擎未就绪"; return
        }
        await SeriesMetaStore.harvest(c, sid: sid, title: s.name, dir: s.url)
        // v1.10.92 只认落盘的真凭证 防harvest无声失败还谎报已认档
        guard let m = SeriesMetaStore.load(s.url), m.sid == sid else {
            busy = false
            note = "认档没成 — 红果接口没回话, 检查手机代理后重试"
            return
        }
        var mm = m
        mm.solo = solo
        try? JSONEncoder().encode(mm).write(to: SeriesMetaStore.file(s.url))
        HGTrail.note("rebind ok \(s.name) -> \(mm.svrTitle) solo=\(solo)")
        busy = false
        note = "已认档：\(mm.svrTitle)"
    }
}

// v1.10.116 手动并册选册弹窗: 搜索+点名, 选中即两本盖章同册(纯本地钦定)
struct MergeSheet: View {
    let src: Series
    let cands: [Series]
    let onPick: (Series) -> Void
    @Environment(\.dismiss) private var dc
    @State private var q = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("先不合（关闭）") { dc() }
                        .tint(.secondary)
                }
                Section("把「\(src.name)」并入哪一册？") {
                    ForEach(filtered) { o in
                        Button { onPick(o) } label: {
                            HStack {
                                Text(o.name).font(.body.weight(.medium))
                                Spacer()
                                Text("\(o.count)集").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $q, prompt: "搜剧名")
            .navigationTitle("手动并入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dc() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filtered: [Series] {
        q.isEmpty ? cands : cands.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}
