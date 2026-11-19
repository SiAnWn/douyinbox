import SwiftUI
import UIKit

// MARK: - v1.10.85 多季归册(用户点单): "云渺 / 云渺2 / 云渺·第二季" 这类同名多册
// 在剧墙归成一张册卡, 点开分季挑。纯本地名字分组, 不联网不碰库结构。

struct ShelfGroup: Identifiable {
    let id: String              // 册基名
    let vols: [Series]          // 已按季号升序
    var isPack: Bool { vols.count > 1 }
    var cover: URL? { vols.first?.cover }
    var epTotal: Int { vols.reduce(0) { $0 + $1.count } }
}

enum DramaShelf {
    // 尾巴季号剥离: "第N季/部"、"-N"、" N"、裸"N"、"Season N"、汉字季
    static func base(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        let zh = "[一二三四五六七八九十两]"
        var guard0 = 0
        while n.count > 2, guard0 < 6 {
            guard0 += 1
            var changed = false
            for pat in ["第\\s*\\d+\\s*[季部]$", "\\s*[季部]\\s*\\d+$",
                        "\\s*[\\-－—_·]\\s*\\d{1,3}$", "\\s+\\d{1,3}$",
                        "(?i)\\s*season\\s*\\d+$",
                        "第\\s*\(zh)\\s*[季部]$", "\\s*[季部]\\s*\(zh)$"] {
                if let r = n.range(of: pat, options: [.regularExpression, .caseInsensitive]) {
                    let cut = String(n[n.startIndex..<r.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if cut.count >= 2 { n = cut; changed = true }
                    break
                }
            }
            if !changed { break }
        }
        return n.isEmpty ? name : n
    }

    // 季号(排序用): 从原名尾提取, 取不到=0
    static func seasonNo(_ name: String) -> Int {
        let zhMap = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                     "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "两": 2]
        if let r = name.range(of: "(第\\s*(\\d+)\\s*[季部]|(\\d+)\\s*[季部]|season\\s*(\\d+))$",
                              options: [.regularExpression, .caseInsensitive]) {
            let digits = name[r].filter { $0.isNumber }
            return Int(digits) ?? 0
        }
        for (ch, v) in zhMap {
            if name.range(of: "第\\s*" + ch + "\\s*[季部]$", options: .regularExpression) != nil { return v }
            if name.range(of: "[\\-－—_·\\s]" + ch + "\\s*[季部]$", options: .regularExpression) != nil { return v }
        }
        if let r = name.range(of: "[\\-－—_·\\s](\\d{1,3})$", options: .regularExpression) {
            let digits = name[r].filter { $0.isNumber }
            return Int(digits) ?? 0
        }
        return 0
    }

    static func group(_ list: [Series]) -> [ShelfGroup] {
        var dict: [String: [Series]] = [:]
        for s in list {
            dict[base(s.name), default: []].append(s)
        }
        return dict.map { k, v in
            ShelfGroup(id: k, vols: v.sorted { a, b in
                let sa = seasonNo(a.name), sb = seasonNo(b.name)
                if sa != sb { return sa < sb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
        }.sorted { g1, g2 in
            // 册(多季)优先沉后按集数, 单册按更新时间感(名字序) — 与剧墙原排序气质一致
            if g1.isPack != g2.isPack { return !g1.isPack }
            return g1.id.localizedStandardCompare(g2.id) == .orderedAscending
        }
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
                        Button { openPack = g } label: { cell(g.id, g.cover, "\(g.vols.count)季·\(g.epTotal)集", pack: true) }
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
                                        if let c = s.cover { Thumb(url: c).resizable().scaledToFill() }
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
                .navigationTitle(g.id)
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
