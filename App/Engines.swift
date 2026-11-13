import Foundation
import WebKit

// MARK: - 引擎选择（设置页切换；key 与产品绑定）
enum Engine: String, CaseIterable {
    case web        // 浏览器直连：免费、慢、最高约 4K30
    case dyjx       // ifphp dyjx：抖音原画（4K60）
    case svparse    // ifphp svparse：多平台（抖音/B站/快手）

    var label: String {
        switch self {
        case .web: return "浏览器直连（免费·约4K30·慢）"
        case .dyjx: return "抖音原画 API（4K60·耗配额）"
        case .svparse: return "多平台 API（抖音/B站/快手）"
        }
    }
    var isIfphp: Bool { self != .web }
}

enum EngineStore {
    private static let key = "parseEngine"
    static var current: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dyjx }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum KeyStore {
    private static let dyjxKey = "ifphpApiKey"
    private static let svKey = "svApiKey"
    static func value(for e: Engine) -> String {
        e == .svparse ? (UserDefaults.standard.string(forKey: svKey) ?? "")
                      : (UserDefaults.standard.string(forKey: dyjxKey) ?? "")
    }
    static func set(_ v: String, for e: Engine) {
        let k = e == .svparse ? svKey : dyjxKey
        UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: k)
    }
    static var legacyMigrated: Bool {
        UserDefaults.standard.bool(forKey: "legacyKeyMigrated")
    }
}

// 引擎允许的平台域名
enum Support {
    // svparse 聚合口实测/官方支持的平台分享域名（海外站按接口方实测为准，失败会给明确提示）
    static let multiHosts = ["douyin.com", "bilibili.com", "kuaishou.com", "weixin.qq.com",
                             "xiaohongshu.com", "xhslink.com", "weibo.com", "weibo.cn", "zhihu.com",
                             "ixigua.com", "haokan.baidu.com", "acfun.cn", "huya.com",
                             "youtube.com", "youtu.be", "tiktok.com", "twitter.com", "x.com",
                             "instagram.com", "weishi.qq.com", "meipai.com", "56.com", "v.douyin"]
    static func hostOK(_ url: String, _ e: Engine) -> Bool {
        switch e {
        case .web: return url.contains("douyin.com")
        case .dyjx: return url.contains("douyin.com")
        case .svparse: return Support.multiHosts.contains { url.contains($0) }
        }
    }
}

// MARK: - 统一解析入口
enum ParseRouter {
    @MainActor
    static func parse(link: String) async throws -> ParseResult {
        switch EngineStore.current {
        case .web:
            return try await WebViewParser().parse(link: link)
        case .dyjx:
            return try await ifphpParse(endpoint: "dyjx", key: KeyStore.value(for: .dyjx), link: link)
        case .svparse:
            return try await ifphpParse(endpoint: "svparse", key: KeyStore.value(for: .svparse), link: link)
        }
    }

    // 合集批量用：指定引擎直连 ifphp（内部自动记录配额）
    @MainActor
    static func originalURL(link: String) async throws -> URL {
        let r = try await parse(link: link)
        guard let top = r.options.first else { throw GError.noStream }
        return top.url
    }
}

// MARK: - ifphp 通用解析（dyjx / svparse 同构）
func ifphpParse(endpoint: String, key: String, link: String) async throws -> ParseResult {
    guard let u = RegexHelper.firstFullURL(link) else { throw GError.noURL }
    guard !key.isEmpty else { throw GError.failed("请先在 ⚙ 设置里填写该引擎的接口 Key") }
    guard var comp = URLComponents(string: "https://api-new.ifphp.com/api/\(endpoint)") else { throw GError.noData }
    comp.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "url", value: u)]
    guard let reqURL = comp.url else { throw GError.noData }
    var req = URLRequest(url: reqURL)
    req.setValue(DouyinAPI.ua, forHTTPHeaderField: "User-Agent")
    CallStats.record()
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
        // 失败也常带 JSON 说明(如 422)：优先把 msg 透出来
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = (obj["msg"] as? String) ?? (obj["message"] as? String), !m.isEmpty {
            throw GError.failed(m)
        }
        throw GError.http(h.statusCode)
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GError.noData }
    let code = (obj["code"] as? Int) ?? ((obj["code"] as? NSNumber)?.intValue ?? -1)
    if code != 200 {
        let m = (obj["msg"] as? String) ?? (obj["message"] as? String) ?? (obj["error"] as? String) ?? "解析失败"
        throw GError.failed(m)
    }
    guard let d = obj["data"] as? [String: Any] else { throw GError.noData }
    let title = (d["desc"] as? String) ?? (d["title"] as? String) ?? ""
    let author = ((d["author"] as? [String: Any])?["name"] as? String)
        ?? ((d["author"] as? [String: Any])?["nickname"] as? String) ?? ""
    let vid = strOf(d["video_id"]) ?? ""
    var opts: [QualityOption] = []
    // data.url 多数是字符串；个别平台回对象 {url:...} / {default:...}，都兼容
    let rawURL = (d["url"] as? String)
        ?? ((d["url"] as? [String: Any])?["url"] as? String)
        ?? ((d["url"] as? [String: Any])?["default"] as? String)
    if let s = rawURL, let uu = URL(string: s) {
        opts.append(QualityOption(label: "原画（最高画质）", url: uu,
            width: intOf(d["width"]) ?? 0, height: intOf(d["height"]) ?? 0,
            sizeBytes: intOf(d["size"]) ?? 0, isOriginal: true,
            isHLS: s.lowercased().contains(".m3u8")))
    }
    if let vb = d["video_backup"] as? [[String: Any]] {
        for b in vb {
            guard let s = b["url"] as? String, let uu = URL(string: s) else { continue }
            let label = (b["label"] as? String) ?? (b["quality"] as? String) ?? "视频"
            opts.append(QualityOption(label: label, url: uu,
                width: intOf(b["width"]) ?? 0, height: intOf(b["height"]) ?? 0,
                sizeBytes: intOf(b["size"]) ?? 0, isOriginal: false))
        }
    }
    if opts.isEmpty { throw GError.noStream }
    return ParseResult(videoID: vid.isEmpty ? u : vid, title: title, author: author, options: opts)
}

// MARK: - 浏览器引擎（移植自 DouyinGrab 初版，已验证）
@MainActor
final class WebViewParser: NSObject, WKScriptMessageHandler {
    private var web: WKWebView?
    private var cont: CheckedContinuation<Data, Error>?
    private var settled = false

    func parse(link: String) async throws -> ParseResult {
        guard let u = RegexHelper.firstFullURL(link), u.contains("douyin.com") else {
            throw GError.failed("浏览器引擎仅支持抖音链接（B站等请用多平台引擎）")
        }
        guard let id = await resolveID(from: u) else { throw GError.noURL }
        let data = try await fetchDetail(id: id)
        guard let r = pickResult(data) else { throw GError.noStream }
        return r
    }

    private func resolveID(from urlStr: String) async -> String? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(DouyinAPI.ua, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { c in
            let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
                let final = (resp as? HTTPURLResponse)?.url?.absoluteString ?? urlStr
                let id = RegexHelper.firstGroup(final, pattern: "/video/(\\d{15,20})")
                    ?? RegexHelper.firstGroup(final, pattern: "/share/video/(\\d{15,20})")
                c.resume(returning: id)
            }
            task.resume()
        }
    }

    private func fetchDetail(id: String) async throws -> Data {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "gotDetail")
        ucc.addUserScript(WKUserScript(source: hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        w.customUserAgent = DouyinAPI.ua
        web = w
        settled = false
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            cont = c
            if let url = URL(string: "https://www.douyin.com/video/\(id)") { w.load(URLRequest(url: url)) }
            else { fail(GError.noURL) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.fail(GError.timeout)
            }
        }
    }

    private func fail(_ e: Error) {
        guard !settled else { return }
        settled = true
        cont?.resume(throwing: e); cont = nil
        web?.stopLoading(); web = nil
    }
    private func succeed(_ d: Data) {
        guard !settled else { return }
        settled = true
        cont?.resume(returning: d); cont = nil
        web?.stopLoading(); web = nil
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "gotDetail",
           let s = message.body as? String,
           s.contains("aweme_detail"),
           let d = s.data(using: .utf8) {
            Task { @MainActor in self.succeed(d) }
        }
    }

    private func pickResult(_ data: Data) -> ParseResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let det = obj["aweme_detail"] as? [String: Any],
              let v = det["video"] as? [String: Any] else { return nil }
        var seen = Set<String>()
        var cands: [(w: Int, h: Int, url: URL)] = []
        func add(_ pa: Any?) {
            guard let pa = pa as? [String: Any],
                  let arr = pa["url_list"] as? [String],
                  let w = pa["width"] as? Int, let h = pa["height"] as? Int else { return }
            for us in arr {
                if let u = URL(string: us), !seen.contains(us) { seen.insert(us); cands.append((w, h, u)) }
            }
        }
        add(v["play_addr_265"]); add(v["play_addr"])
        let brs = (det["bit_rate_list"] as? [[String: Any]]) ?? (v["bit_rate"] as? [[String: Any]])
        if let brs { for b in brs { add(b["play_addr"]) } }
        cands.sort { ($0.w * $0.h) > ($1.w * $1.h) }
        guard !cands.isEmpty else { return nil }
        var opts: [QualityOption] = []
        for (i, c) in cands.prefix(4).enumerated() {
            let label = i == 0 ? "原画（网页最高 \(c.w)×\(c.h)）" : "备用 \(c.w)×\(c.h)"
            opts.append(QualityOption(label: label, url: c.url, width: c.w, height: c.h, sizeBytes: 0, isOriginal: i == 0))
        }
        let title = (det["desc"] as? String) ?? ""
        let author = ((det["author"] as? [String: Any])?["nickname"] as? String) ?? ""
        let vid = (det["aweme_id"] as? String) ?? ""
        return ParseResult(videoID: vid, title: title, author: author, options: opts)
    }

    private let hookJS = """
    (function(){
      function emit(u,t){ try{ if(u && u.indexOf('aweme/detail')>-1 && t && t.indexOf('aweme_detail')>-1){ window.webkit.messageHandlers.gotDetail.postMessage(t);} }catch(e){} }
      var of=window.fetch;
      if(of){ window.fetch=function(){ var a=arguments, u=(a[0]&&a[0].url)||a[0]; var p=of.apply(this,a); try{ p.then(function(r){ r.clone().text().then(function(t){emit(u,t);}); }); }catch(e){} return p; }; }
      var oo=XMLHttpRequest.prototype.open, os=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open=function(m,u){ this.__u=u; return oo.apply(this,arguments); };
      XMLHttpRequest.prototype.send=function(){ var x=this; x.addEventListener('load',function(){ try{emit(x.__u,x.responseText);}catch(e){} }); return os.apply(this,arguments); };
    })();
    """
}
