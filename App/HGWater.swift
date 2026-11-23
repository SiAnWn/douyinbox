// v1.10.127 网页水闸: 红果官网播放器自用口, 匿名可达, App 三闸门焊死时的活水
//   720P  POST /api/video/protected/play-info?aid=8662  {series_id,item_id,definition:"720p"}
//         需 ttwid 门票(官网首页 set-cookie 白捡) → 回 play_info{main_url=视频轨, audio.main_url=音频轨}
//         DASH 分轨明文 H264/AAC → AVMutableComposition passthrough 合体成完整 mp4
//   360P  POST /api/video/protected/fallback-play-info  {item_id} → main_url 单文件 mp4 直落
// 实证(2026-11-23 用户 HAR + PC 复现): 720p 回 br=1977 完整正片; 1080p 被拒 400(官网封顶 720);
// 不带 ttwid 的 play-info = Bad Request, fallback-play-info 则免票可调。
import AVFoundation

enum HGWater {
    static let site = "https://hongguoduanju.com"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    struct E: LocalizedError { let m: String; var errorDescription: String? { m } }

    // 红果=国内站: 专用直连会话绕开代理层(TUN 下海外出口照样能通, 直连更稳更快)
    static let session: URLSession = {
        let cf = URLSessionConfiguration.ephemeral
        cf.connectionProxyDictionary = [:]
        cf.timeoutIntervalForRequest = 25
        cf.requestCachePolicy = .reloadIgnoringLocalCacheData
        cf.httpAdditionalHeaders = ["User-Agent": ua, "Accept": "application/json",
                                    "Origin": site, "Referer": site + "/"]
        return URLSession(configuration: cf)
    }()

    // ttwid 缓存(UserDefaults); 空=还没领
    static var cachedTtwid: String { UserDefaults.standard.string(forKey: "hgTtwid") ?? "" }

    static func freshTtwid() async -> String {
        guard let url = URL(string: site + "/") else { return cachedTtwid }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await session.data(for: req),
           let hresp = resp as? HTTPURLResponse {
            for (k, v) in hresp.allHeaderFields {
                guard let ks = k as? String, ks.lowercased() == "set-cookie",
                      let vs = v as? String else { continue }
                for piece in vs.split(separator: ";") where piece.contains("ttwid=") {
                    let t = String(piece).trimmingCharacters(in: .whitespaces)
                    UserDefaults.standard.set(t, forKey: "hgTtwid")
                    HGTrail.note("hgwater ttwid 领新 len=\(t.count)")
                    return t
                }
            }
        }
        return cachedTtwid
    }

    static func post(_ path: String, body: [String: String], ticket: Bool, retry: Bool = true) async throws -> [String: Any] {
        await throttle()
        guard let url = URL(string: site + path + "?aid=8662") else { throw E(m: "url?") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var tk = cachedTtwid
        if tk.isEmpty, ticket { tk = await freshTtwid() }
        if !tk.isEmpty { req.setValue(tk, forHTTPHeaderField: "Cookie") }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw E(m: "net " + e_short(error)) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400, ticket, retry, await !freshTtwid().isEmpty {
            return try await post(path, body: body, ticket: ticket, retry: false)
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        let rc = ((obj as? [String: Any])?["base_resp"] as? [String: Any])?["StatusCode"] as? Int ?? -1
        guard code == 200, let j = obj as? [String: Any], rc == 0 else {
            let snip = String(data: data, encoding: .utf8) ?? ""
            throw E(m: "r\(code)/\(rc) " + snip.prefix(60))
        }
        return j
    }

    static func e_short(_ e: Error) -> String { String(e.localizedDescription.prefix(40)) }

    // 节流闸: 官网两条口都是给真人播放器用的, 机器连发必讨 403, 每枪之间垫 1.5s
    private static var lastShot = Date.distantPast
    static func throttle() async {
        let wait = 1.5 - Date().timeIntervalSince(lastShot)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastShot = Date()
    }

    // ---- 下载与合体 ----
    static func dl(_ us: String, _ dst: URL) async -> URL? {
        guard let u = URL(string: us) else { return nil }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(site + "/", forHTTPHeaderField: "Referer")
        guard let (fp, resp) = try? await session.download(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.moveItem(at: fp, to: dst)
        let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
        return size > 300_000 ? dst : nil
    }

    static func mux(_ v: URL, _ a: URL, _ out: URL) async -> Bool {
        await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            // 官网分轨是 DASH 分段 fMP4: 不给这张通行证 AVFoundation 装看不见时长 → insert 必炸(127 真机遗嘱"合体失败"案)
            let opts = ["AVURLAssetMovieFragmentIntervalKey": CMTime.invalid]
            let av = AVURLAsset(url: v, options: opts), aa = AVURLAsset(url: a, options: opts)
            let comp = AVMutableComposition()
            guard let vt = av.tracks(withMediaType: .video).first,
                  let at = aa.tracks(withMediaType: .audio).first,
                  let cvt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let cat = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { HGTrail.note("hgwater mux notrack v=\(av.tracks(withMediaType: .video).count) a=\(aa.tracks(withMediaType: .audio).count) vdur=\(CMTimeGetSeconds(av.duration))"); k.resume(returning: false); return }
            let span = CMTimeRange(start: .zero, duration: av.duration < aa.duration ? av.duration : aa.duration)
            do {
                try cvt.insertTimeRange(span, of: vt, at: .zero)
                try cat.insertTimeRange(span, of: at, at: .zero)
            } catch {
                HGTrail.note("hgwater mux insert " + String(reflecting: type(of: error)) + " span=\(CMTimeGetSeconds(span.duration))")
                k.resume(returning: false); return
            }
            guard let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)
            else { HGTrail.note("hgwater mux noexporter"); k.resume(returning: false); return }
            try? FileManager.default.removeItem(at: out)
            exp.outputURL = out
            exp.outputFileType = .mp4
            exp.exportAsynchronously {
                let why = exp.status == .completed ? "" : (String(reflecting: exp.status) + " " + (exp.error?.localizedDescription ?? "-"))
                if !why.isEmpty { HGTrail.note("hgwater mux exp " + String(why.prefix(70))) }
                k.resume(returning: exp.status == .completed)
            }
        }
    }

    // ---- 两档取片 ----
    static func play720(sid: String, vid: String) async throws -> URL {
        let j = try await post("/api/video/protected/play-info",
                               body: ["series_id": sid, "item_id": vid, "definition": "720p"], ticket: true)
        guard let pi = j["play_info"] as? [String: Any],
              let vu = pi["main_url"] as? String,
              let au = (pi["audio"] as? [String: Any])?["main_url"] as? String
        else { throw E(m: "play_info 无分轨") }
        let tmp = FileManager.default.temporaryDirectory
        async let vr = dl(vu, tmp.appendingPathComponent("wv_\(vid).mp4"))
        async let ar = dl(au, tmp.appendingPathComponent("wa_\(vid).mp4"))
        guard let v = await vr, let a = await ar else { throw E(m: "分轨下载失败") }
        let out = tmp.appendingPathComponent("wm_\(vid).mp4")
        guard await mux(v, a, out) else {
            try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: a)
            throw E(m: "合体失败")
        }
        try? FileManager.default.removeItem(at: v)
        try? FileManager.default.removeItem(at: a)
        return out
    }

    static func play360(vid: String) async throws -> URL {
        let j = try await post("/api/video/protected/fallback-play-info",
                               body: ["item_id": vid], ticket: false)
        guard let u = j["main_url"] as? String else { throw E(m: "无 360 地址") }
        guard let f = await dl(u, FileManager.default.temporaryDirectory.appendingPathComponent("w360_\(vid).mp4"))
        else { throw E(m: "360 下载失败") }
        return f
    }

    /// 主入口: 720P 优先(两轨合体), 失败退 360P 单文件; 成功=已按 rel 落库
    static func save(sid: String, vid: String, rel: String) async -> (Bool, String) {
        var why = ""
        do {
            let tmp = try await play720(sid: sid, vid: vid)
            if SavePaths.write(tmp, rel: rel) {
                HGTrail.note("hgwater 720 ok sid=\(sid) vid=\(vid)")
                try? FileManager.default.removeItem(at: tmp)
                return (true, "")
            }
            why = "720存盘败;"
            try? FileManager.default.removeItem(at: tmp)
        } catch let e { why = "720:" + e_short(e) + ";" }
        do {
            let tmp = try await play360(vid: vid)
            if SavePaths.write(tmp, rel: rel) {
                HGTrail.note("hgwater 360 ok sid=\(sid) vid=\(vid)")
                try? FileManager.default.removeItem(at: tmp)
                return (true, why + "360顶账")
            }
            why += "360存盘败"
            try? FileManager.default.removeItem(at: tmp)
        } catch let e { why += "360:" + e_short(e) }
        HGTrail.note("hgwater 全败 sid=\(sid) vid=\(vid) \(why.prefix(90))")
        return (false, why)
    }
}
