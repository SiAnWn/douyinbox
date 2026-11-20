import SwiftUI
import UIKit

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

    static func group(_ list: [Series]) -> [ShelfGroup] {
        var dict: [String: [Series]] = [:]
        var titles: [String: String] = [:]
        for s in list {
            let b = base(s.name)
            // v1.10.87 标点抹平: "我家娘子，不对劲第四季"与"我家娘子不对劲1：xx"
            // 差的只是逗号 — 分组键剔掉所有标点空格, 只留汉字与字母数字
            let key = norm(b)
            dict[key, default: []].append(s)
            if titles[key] == nil || base(s.name).count < (titles[key] ?? "zzzz").count {
                titles[key] = b
            }
        }
        return dict.map { k, v in
            ShelfGroup(id: k, title: titles[k] ?? k, vols: v.sorted { a, b in
                let sa = seasonNo(a.name), sb = seasonNo(b.name)
                if sa != sb { return sa < sb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
        }.sorted { g1, g2 in
            // 册(多季)优先沉后按集数, 单册按更新时间感(名字序) — 与剧墙原排序气质一致
            if g1.isPack != g2.isPack { return !g1.isPack }
            return g1.title.localizedStandardCompare(g2.title) == .orderedAscending
        }
    }

    // 只留字母数字(CJK 也算 alphanumeric) — 逗号空格标点全抹
    static func norm(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}

// 剧墙: 单册=原卡直接进; 多季册=一张卡挂"全N季"徽, 点开分季清单
// destination 由 callers 供给(短剧=DramaEpisodes / 私盒=PrivateEpisodes)
struct ShelfGrid<Destination: View>: View {
    let groups: [ShelfGroup]
    let destination: (Series) -> Destination
    @State private var openPack: ShelfGroup?
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(groups) { g in
                    if g.isPack {
                        Button { openPack = g } label: { cell(g.title, g.cover, "\(g.vols.count)季·\(g.epTotal)集", pack: true) }
                            .buttonStyle(.plain)
                    } else if let s = g.vols.first {
                        NavigationLink(value: s) { cell(s.name, s.cover, "\(s.count)集", pack: false) }
                            .buttonStyle(.plain)
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
                                    Text("\(s.count) 集").font(.caption).foregroundStyle(.secondary)
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
