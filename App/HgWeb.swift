import Foundation

// 红果官网页(hongguoduanju.com/player/<sid>)免签抓详情增强数据 v1.10.36
// 学 iDuanJu 思路自写: HTML 里 window._ROUTER_DATA 内嵌 JSON, 花括号配对截取。
// 只当锦上添花的第二腿: 失败静默 nil, 绝不为它卡主详情。
// 注意: 域名属国内站, 手机 Clash 最好加 hongguoduanju.com DIRECT 规则; 海外出口最多慢不报错。

struct HgWebCelebrity: Hashable {
    let id: String
    let name: String
    let avatar: String
    let role: String
}

struct HgWebDetail {
    var favorite = 0
    var rating = ""
    var ratingCount = 0
    var hotText = ""
    var tags: [String] = []
    var celebrities: [HgWebCelebrity] = []
}

enum HgWeb {
    static func detail(_ sid: String) async -> HgWebDetail? {
        guard let u = URL(string: "https://hongguoduanju.com/player/" + sid) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("https://hongguoduanju.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8),
              html.contains("_ROUTER_DATA") else {
            HGTrail.note("hgweb miss sid=" + sid)
            return nil
        }
        let out = parse(html, sid)
        HGTrail.note("hgweb " + (out == nil ? "parse-fail" : "ok fav=\(out!.favorite) celebs=\(out!.celebrities.count) tags=\(out!.tags.count)") + " sid=" + sid)
        return out
    }

    static func parse(_ html: String, _ sid: String) -> HgWebDetail? {
        guard let r = html.range(of: "window._ROUTER_DATA") else { return nil }
        // 找 = 后第一个 {
        var i = r.upperBound
        while i < html.endIndex, html[i] != "{" { i = html.index(after: i) }
        guard i < html.endIndex else { return nil }
        let start = i
        // 花括号配对状态机(引号+转义)
        var depth = 0
        var inStr = false
        var esc = false
        var end = html.endIndex
        while i < html.endIndex {
            let ch = html[i]
            if esc { esc = false }
            else if ch == "\\", inStr { esc = true }
            else if ch == "\"" { inStr.toggle() }
            else if !inStr {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { end = html.index(after: i); break }
                }
            }
            i = html.index(after: i)
        }
        guard end < html.endIndex || depth == 0,
              let obj = try? JSONSerialization.jsonObject(
                with: Data(String(html[start..<end]).utf8)) as? [String: Any],
              let loader = obj["loaderData"] as? [String: Any] else { return nil }
        // 页面键名两种姿势都试
        var page: [String: Any]?
        for k in ["player_\(sid)/page", "player/\(sid)"] {
            if let p = loader[k] as? [String: Any] { page = p; break }
        }
        if page == nil { page = loader.values.first { ($0 as? [String: Any])?["seriesDetail"] != nil } as? [String: Any] }
        guard let pg = page else { return nil }
        var out = HgWebDetail()
        if let so = pg["seriesSocialInfo"] as? [String: Any] {
            out.favorite = digInt(so["series_favorite_count"]) ?? 0
            out.rating = digStr(so["rating"])
            out.ratingCount = digInt(so["rating_count"]) ?? 0
            if let hs = so["hot_score_data"] as? [String: Any] { out.hotText = digStr(hs["text"]) }
        }
        let sd = pg["seriesDetail"] as? [String: Any] ?? [:]
        if let tg = sd["tags"] as? [Any] {
            out.tags = tg.compactMap { v in
                if let s = v as? String { return s }
                return digStr((v as? [String: Any])?["name"])
            }.filter { !$0.isEmpty }.prefix(8).map { $0 }
        }
        if let cs = sd["celebrities"] as? [[String: Any]] {
            out.celebrities = cs.prefix(12).compactMap { c in
                let nm = digStr(c["nickname"])
                guard !nm.isEmpty else { return nil }
                let id = digStr(c["celebrity_id"]) ?? digStr(c["actor_id"])
                return HgWebCelebrity(id: id.isEmpty ? nm : id,
                                      name: nm,
                                      avatar: digStr(c["avatar"]),
                                      role: digStr(c["sub_title"]).isEmpty ? digStr(c["role"]) : digStr(c["sub_title"]))
            }
        }
        return out
    }

    private static func digStr(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    private static func digInt(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String {
            if let n = Int(s) { return n }
            if let d = Double(s) { return Int(d) }
        }
        return nil
    }
}
