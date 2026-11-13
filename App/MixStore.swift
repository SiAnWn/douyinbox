import Foundation

// MARK: - 合集数据（免费公开接口，不耗 ifphp 配额）
struct MixEpisode {
    let id: String
    let title: String
    let embedded: URL?
    var num: Int = 0
}

struct MixData: Identifiable {
    let id: String          // mixID
    let name: String
    let eps: [MixEpisode]
}

enum MixAPI {
    static let iosUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    // 跟随短链跳转拿最终 URL（纯 HTTP，已验证）
    static func resolve(_ link: String) async -> String? {
        guard let u = RegexHelper.firstFullURL(link), let url = URL(string: u) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(iosUA, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
                c.resume(returning: (resp as? HTTPURLResponse)?.url?.absoluteString ?? u)
            }
            task.resume()
        }
    }

    // range 含前缀会连字符返回，用 group 提纯 ID
    static func mixID(from finalURL: String) -> String? {
        RegexHelper.firstGroup(finalURL, pattern: "/mix(?:/detail)?/(\\d{15,20})")
            ?? RegexHelper.firstGroup(finalURL, pattern: "mix_id=(\\d{15,20})")
            ?? RegexHelper.firstGroup(finalURL, pattern: "/collection/(\\d{15,20})")
    }

    static func fetch(mixID: String) async throws -> MixData {
        var eps: [MixEpisode] = []
        var cursor = 0
        var name = ""
        for _ in 0..<40 {   // 页上限护栏
            let u = "https://www.iesdouyin.com/aweme/v1/mix/aweme/?reflow_source=reflow_page"
                  + "&web_id=undefined&device_id=undefined&aid=1128&mix_id=\(mixID)"
                  + "&count=20&cursor=\(cursor)&device_type=&device_platform=web"
                  + "&publish_videocut=0&app=aweme&os=ios&ac=wifi"
            let d = try await getJSON(u)
            let lst = (d["aweme_list"] as? [[String: Any]]) ?? []
            for item in lst {
                guard let id = strOf(item["aweme_id"]) else { continue }
                let title = (item["desc"] as? String) ?? ""
                var emb: URL? = nil
                if let v = item["video"] as? [String: Any],
                   let pa = v["play_addr"] as? [String: Any],
                   let arr = pa["url_list"] as? [String], let first = arr.first {
                    emb = URL(string: first)
                }
                eps.append(MixEpisode(id: id, title: title.isEmpty ? "第\(eps.count + 1)集" : title, embedded: emb))
            }
            if name.isEmpty { name = (d["mix_name"] as? String) ?? "" }
            let hasMore = intOf(d["has_more"]) ?? ((d["has_more"] as? Bool == true) ? 1 : 0)
            cursor = intOf(d["cursor"]) ?? (cursor + lst.count)
            if lst.isEmpty || hasMore == 0 { break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        if eps.isEmpty { throw GError.failed("没读到合集内容（可能是付费合集或接口变动）") }
        for i in eps.indices { eps[i].num = i + 1 }
        if name.isEmpty {
            let du = "https://www.iesdouyin.com/aweme/v1/mix/detail/?reflow_source=reflow_page"
                   + "&web_id=undefined&device_id=undefined&aid=1128&mix_id=\(mixID)"
                   + "&device_type=&device_platform=web&app=aweme&os=ios&ac=wifi"
            if let d = try? await getJSON(du),
               let mi = d["mix_info"] as? [String: Any],
               let n = mi["mix_name"] as? String, !n.isEmpty { name = n }
        }
        return MixData(id: mixID, name: name.isEmpty ? "合集\(mixID.prefix(6))" : name, eps: eps)
    }

    private static func getJSON(_ u: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: u)!)
        req.setValue(iosUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.iesdouyin.com/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { throw GError.http(h.statusCode) }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GError.noData }
        return d
    }
}

// MARK: - 断点/追更清单：mixID -> [集ID: 相对路径]
enum MixManifest {
    static func map(_ mixID: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: "mixdl_\(mixID)") as? [String: String]) ?? [:]
    }
    static func record(_ mixID: String, epID: String, rel: String) {
        var m = map(mixID); m[epID] = rel
        UserDefaults.standard.set(m, forKey: "mixdl_\(mixID)")
    }
}

// MARK: - 批量执行器
@MainActor
final class BatchRunner: ObservableObject {
    enum Phase { case ready, running, done, failed }
    @Published var phase: Phase = .ready
    @Published var total = 0, got = 0, skipped = 0, failed = 0
    @Published var current = ""

    private var cancelled = false

    func cancel() { cancelled = true }

    // base: "短剧"/"私密"；useEngine: true=每集调引擎拿原画(1配额/集)；false=用列表内嵌地址(0配额)
    func start(mix: MixData, base: String, useEngine: Bool, folderName: String,
               onFinish: @escaping () -> Void) async {
        phase = .running; cancelled = false
        total = mix.eps.count; got = 0; skipped = 0; failed = 0
        let rec = MixManifest.map(mix.id)
        let folder = Naming.sanitize(folderName.isEmpty ? mix.name : folderName)
        var engineFailStreak = 0
        for ep in mix.eps {
            if cancelled { break }
            current = "第 \(ep.num) 集 · \(String(ep.title.prefix(24)))"
            if let rel = rec[ep.id], SavePaths.exists(rel: rel) { skipped += 1; continue }
            var dlURL: URL?
            if useEngine {
                // 尊重 15 次/分限制
                while CallStats.current().minute >= CallStats.limits.minute {
                    if cancelled { break }
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
                do {
                    dlURL = try await ParseRouter.originalURL(link: "https://www.douyin.com/video/\(ep.id)")
                    engineFailStreak = 0
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    engineFailStreak += 1
                    if ep.embedded == nil && engineFailStreak >= 3 { break }
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                }
                if dlURL == nil { dlURL = ep.embedded }   // 引擎失败退内嵌
            } else {
                dlURL = ep.embedded
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard let u2 = dlURL else { failed += 1; continue }
            do {
                let file = try await DouyinAPI.download(u2) { _, _ in }
                let rel = "\(base)/\(folder)/\(Naming.epName(num: ep.num, title: ep.title))"
                if SavePaths.write(file, rel: rel) {
                    MixManifest.record(mix.id, epID: ep.id, rel: rel)
                    got += 1
                } else { failed += 1 }
                try? FileManager.default.removeItem(at: file)
            } catch { failed += 1 }
        }
        phase = cancelled ? .failed : .done
        if cancelled { current = "已取消（已下的保留，再粘同链接可续传）" }
        onFinish()
    }
}
