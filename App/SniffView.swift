import SwiftUI
import WebKit

// ===================== 🌐 浏览器嗅探：任意网页 → m3u8/mp4 候选 → 下载入库 =====================

enum SniffConst {
    // 和 WKWebView 用同一套身份，让"网页能看 = 能下"
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    // 桌面身份：抖音网页播放器（登录态）会吐 1080p 直链（IDM 实测同款）
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
}

@MainActor
final class SniffVM: ObservableObject {
    struct Snip: Identifiable {
        let id: String          // 完整 URL
        var kind: String        // "m3u8" / "mp4"
        var note = ""
        var tag = ""            // 智能标签：如 "本集·1080"
        var dsRank = 99         // tos ds 档位（4=1080 6=576，越小越高清）
        var frac = -1.0         // -1 未开始
        var done = false
        var downloaded = false
    }
    @Published var items: [Snip] = []
    @Published var pageURL = ""
    @Published var pageTitle = ""
    @Published var hint = ""
    var currentVid = ""          // 当前播放页的 video id（判定"本集"）

    private static func qv(_ url: String, _ k: String) -> String {
        guard let r = url.range(of: k + "=") else { return "" }
        let tail = url[r.upperBound...]
        let end = tail.firstIndex(where: { $0 == "&" }) ?? tail.endIndex
        return String(tail[..<end])
    }

    func add(_ url: String) {
        guard url.hasPrefix("http"), items.count < 40 else { return }
        let low = url.lowercased()
        let isVid = low.contains("m3u8") || low.contains(".mp4")
            || low.contains("douyinvod") || low.contains("video_mp4") || low.contains("/video/tos/")
        if isVid {
            // 过滤明显非媒体
            for drop in [".js", ".css", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".woff", ".ico", ".webp", ".html"] where low.contains(drop) && !low.contains("m3u8") { return }
            // 按视频本体归并：video_id 优先，退回 host+path
            let vid = Self.qv(low, "video_id")
            let key = !vid.isEmpty ? vid : ((low.components(separatedBy: "?").first) ?? low)
            let ds = Int(Self.qv(low, "ds")) ?? 99
            var tag = ""
            if kindIsMp4(low) {
                if !vid.isEmpty, vid == currentVid { tag += "本集·" }
                else if !vid.isEmpty { tag += "预载·" }
                tag += ds == 4 ? "1080" : (ds == 6 ? "576" : (ds < 99 ? "档\(ds)" : ""))
            }
            if let i = items.firstIndex(where: {
                let kv = Self.qv($0.id.lowercased(), "video_id")
                return (!vid.isEmpty && !kv.isEmpty && kv == vid) ||
                       (vid.isEmpty && kv.isEmpty && (($0.id.lowercased().components(separatedBy: "?").first) ?? "") == key)
            }) {
                // 同集重复到达：只留更清晰档位那条
                if ds < items[i].dsRank {
                    items[i] = Snip(id: url, kind: kindIsMp4(low) ? "mp4" : "m3u8", tag: tag, dsRank: ds)
                    resort()
                }
                return
            }
            let k = kindIsMp4(low) ? "mp4" : "m3u8"
            items.append(Snip(id: url, kind: k, tag: tag, dsRank: ds))
            resort()
        }
    }
    private func kindIsMp4(_ low: String) -> Bool { !low.contains("m3u8") }
    private func resort() {
        items.sort { a, b in
            if (a.kind == "mp4") != (b.kind == "mp4") { return a.kind == "mp4" }
            return a.dsRank < b.dsRank
        }
    }
    func update(_ url: String, _ block: (inout Snip) -> Void) {
        if let i = items.firstIndex(where: { $0.id == url }) { block(&items[i]) }
    }
}

private func sniffCookies(host: String) async -> String {
    await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cs in
            let rel = cs.filter { $0.domain.contains(host) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            c.resume(returning: rel)
        }
    }
}

struct SniffView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = SniffVM()
    @StateObject private var bridge = BrowserBridge()
    @State private var urlInput = ""
    @State private var webPlay: VideoItem?
    @State private var desktopUA: Bool
    let seed: String
    init(seed: String = "", desktop: Bool = false) {
        self.seed = seed
        _desktopUA = State(initialValue: UserDefaults.standard.object(forKey: "sniffDesktop") as? Bool ?? desktop)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("网址", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { go() }
                Button("前往") { go() }.font(.footnote)
                Button("重扫") { bridge.deepScan() }.font(.footnote)
                Button("停止") { bridge.webView?.stopLoading() }.font(.footnote)
            }
            .padding(10)

            Picker("身份", selection: $desktopUA) {
                Text("手机网页").tag(false)
                Text("电脑网页（1080p 直链·需登录）").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)

            SiteBrowser(bridge: bridge, onURL: { u, t in
                vm.pageURL = u ?? vm.pageURL
                if let u = u, let r = u.range(of: "/video/(\\d{15,20})", options: .regularExpression) {
                    vm.currentVid = String(r.dropFirst("/video/".count))
                }
                if let t = t, !t.isEmpty { vm.pageTitle = t }
                vm.hint = ""
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                Text(vm.hint.isEmpty ? "候选 \(vm.items.count) 个 —— 网页里点播放即可自动嗅取，也可点「重扫」" : vm.hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                if vm.items.isEmpty {
                    Spacer()
                } else {
                    List {
                        ForEach($vm.items) { $s in
                            Button {
                                if !s.downloaded && s.frac < 0 { startDownload(s) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(s.kind == "m3u8" ? "HLS" : "MP4")
                                            .font(.caption2).bold()
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(s.kind == "m3u8" ? Color.purple.opacity(0.25) : Color.green.opacity(0.25))
                                            .foregroundStyle(s.kind == "m3u8" ? Color.purple : Color.green)
                                            .clipShape(Capsule())
                                        if !s.tag.isEmpty {
                                            Text(s.tag)
                                                .font(.caption2).bold()
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(s.tag.contains("1080") ? Color.orange.opacity(0.3) : Color.gray.opacity(0.2))
                                                .foregroundStyle(s.tag.contains("1080") ? Color.orange : Color.secondary)
                                                .clipShape(Capsule())
                                        }
                                        Text(s.id).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                        Spacer()
                                        if s.frac >= 0 {
                                            ProgressView(value: Double(min(max(s.frac, 0), 1)))
                                                .frame(width: 54).scaleEffect(0.8)
                                        }
                                    }
                                    if !s.note.isEmpty {
                                        Text(s.note).font(.caption2).foregroundStyle(s.downloaded ? Color.green : Color.secondary)
                                    }
                                    Text(s.downloaded ? "已入库 · 长按可试播/复制" : "点按下载 · 长按更多操作")
                                        .font(.caption2).foregroundStyle(Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button("复制链接") { UIPasteboard.general.string = s.id }
                                Button("在播放器打开") {
                                    if let v = VideoItem.fromURLString(s.id, kind: s.kind) { webPlay = v }
                                }
                            }
                        }
                    }
                    .frame(height: 230)
                }
            }
            .navigationTitle("网页嗅探")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .fullScreenCover(item: $webPlay) { v in
                InlinePlayer(video: v)
            }
        }
        .onAppear {
            bridge.vm = vm
            bridge.setDesktop(desktopUA, reload: false)
            if !seed.isEmpty && urlInput.isEmpty {
                urlInput = seed
                if let r = seed.range(of: "/video/(\\d{15,20})", options: .regularExpression) {
                    vm.currentVid = String(r.dropFirst("/video/".count))
                }
                bridge.load(seed)
            }
        }
        .onChange(of: desktopUA) { v in
            UserDefaults.standard.set(v, forKey: "sniffDesktop")
            bridge.setDesktop(v, reload: true)
        }
    }

    private func go() {
        var u = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return }
        if !u.contains("://") { u = "https://" + u }
        bridge.load(u)
    }

    private func startDownload(_ s: SniffVM.Snip) {
        guard let u = URL(string: s.id) else { return }
        let rawTitle = vm.pageTitle.isEmpty ? u.deletingPathExtension().lastPathComponent : vm.pageTitle
        let title = Naming.sanitize(String(rawTitle.prefix(48)))
        let stamp = Int(Date().timeIntervalSince1970)
        let ext = s.kind == "m3u8" ? "ts" : "mp4"
        let destRel = "\(title)_\(stamp).\(ext)"
        vm.update(s.id) { $0.frac = 0; $0.note = "开始…" }
        Task { @MainActor in
            do {
                if s.kind == "m3u8" {
                    let cookie = await sniffCookies(host: u.host ?? "")
                    let refer = vm.pageURL.isEmpty ? s.id : vm.pageURL
                    let tok = HLSToken(referer: refer, cookie: cookie, headers: [:])
                    let saved = try await HLSSmart.download(baseName: "\(title)_\(stamp)",
                        m3u8Str: s.id, tok: tok, preferApple: false) { frac, sps in
                            Task { @MainActor in
                                self.vm.update(s.id) { cur in
                                    cur.frac = frac
                                    cur.note = "\(Int(frac * 100))% · \(Naming.fmtSpeed(sps))"
                                }
                            }
                        }
                    vm.update(s.id) { $0.frac = 1; $0.done = true; $0.downloaded = true; $0.note = "已存入视频库(\(saved))" }
                    app.refresh()
                } else {
                    let ck = await sniffCookies(host: u.host ?? "")
                    let refer = vm.pageURL.isEmpty ? s.id : vm.pageURL
                    // tos 直链实测裸连可下；带页面身份证则可能 UA/签名配套被拒 →
                    // 先裸下，失败再带身份重试
                    let prog: @Sendable (Double, Double) -> Void = { frac, sps in
                        Task { @MainActor in
                            self.vm.update(s.id) { cur in
                                cur.frac = frac
                                cur.note = "\(Int(frac * 100))% · \(Naming.fmtSpeed(sps))"
                            }
                        }
                    }
                    let attempts: [(String, String, String)] = [
                        (desktopUA ? SniffConst.desktopUA : SniffConst.ua, "", ""),   // 裸连+对味UA
                        (desktopUA ? SniffConst.desktopUA : SniffConst.ua, refer, ck) // 带页面身份证
                    ]
                    var file: URL?
                    var lastErr: Error?
                    for (ua, rf, cok) in attempts {
                        do {
                            let got = try await DouyinAPI.download(u, referer: rf, cookie: cok,
                                                                   uaOverride: ua, progress: prog)
                            // 魔数验货：合法 mp4 第 4~8 字节必为 ftyp，防 CDN 错误页冒充
                            let magicOK: Bool = {
                                guard let h = try? Data(contentsOf: got, options: .mappedIfSafe).prefix(12),
                                      h.count >= 8 else { return false }
                                return String(data: h.subdata(in: 4..<8), encoding: .ascii) == "ftyp"
                            }()
                            guard magicOK else {
                                try? FileManager.default.removeItem(at: got)
                                throw GError.failed("非视频内容(疑似错误页)")
                            }
                            file = got
                            break
                        } catch {
                            lastErr = error
                            vm.update(s.id) { $0.note = "换姿势重试…" }
                        }
                    }
                    guard let got = file else { throw lastErr ?? GError.failed("下载失败") }
                    let sz = (try? FileManager.default.attributesOfItem(atPath: got.path))?[.size] as? Int ?? 0
                    if sz < 30_000 {
                        try? FileManager.default.removeItem(at: got)
                        vm.update(s.id) { $0.frac = -1; $0.note = "站点拒直下(仅\(sz / 1024)KB)：优先用HLS候选，或先在网页里点播放再试" }
                    } else if SavePaths.write(got, rel: destRel) {
                        try? FileManager.default.removeItem(at: got)
                        vm.update(s.id) { $0.frac = 1; $0.done = true; $0.downloaded = true; $0.note = "已存入视频库(\(destRel))" }
                        app.refresh()
                    } else {
                        vm.update(s.id) { $0.frac = -1; $0.note = "保存失败" }
                    }
                }
            } catch {
                vm.update(s.id) { $0.frac = -1; $0.note = "失败: \(error.localizedDescription)" }
            }
        }
    }
}

// ===================== WKWebView 桥 =====================
final class BrowserBridge: ObservableObject {
    weak var webView: WKWebView?
    weak var vm: SniffVM?

    func setDesktop(_ desktop: Bool, reload: Bool) {
        webView?.customUserAgent = desktop ? SniffConst.desktopUA : SniffConst.ua
        if reload, webView?.url != nil { webView?.reload() }
    }
    func load(_ u: String) {
        guard let url = URL(string: u) else { return }
        webView?.load(URLRequest(url: url))
    }
    func deepScan() {
        webView?.evaluateJavaScript("window.__deepScan && window.__deepScan()", completionHandler: nil)
    }
    func hintBlocked() {
        Task { @MainActor in
            self.vm?.hint = "媒体直链已拦进列表（不再被全屏播放器抢走），点按该行即可下载"
        }
    }
    func report(t: String, u: String) {
        _ = t
        Task { @MainActor in self.vm?.add(u) }
    }
    func reportList(_ urls: [String]) {
        Task { @MainActor in
            for x in urls { self.vm?.add(x) }
        }
    }
}

struct SiteBrowser: UIViewRepresentable {
    let bridge: BrowserBridge
    let onURL: (String?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, onURL: onURL) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "sniff")
        ucc.addUserScript(WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        cfg.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        w.customUserAgent = SniffConst.ua
        bridge.webView = w
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        let bridge: BrowserBridge
        let onURL: (String?, String?) -> Void
        init(bridge: BrowserBridge, onURL: @escaping (String?, String?) -> Void) {
            self.bridge = bridge
            self.onURL = onURL
        }
        // 主框架直接导航到媒体地址 → 拦下来进列表，不让 WebKit 独占全屏
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let u = navigationAction.request.url?.absoluteString ?? ""
            let low = u.lowercased()
            let isMedia = low.contains(".m3u8") || low.contains(".mp4") || low.contains(".ts")
            if navigationAction.targetFrame?.isMainFrame == true && isMedia {
                bridge.report(t: "net", u: u)
                bridge.hintBlocked()
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let resp = navigationResponse.response as? HTTPURLResponse,
               let u = resp.url?.absoluteString {
                let mime = (resp.mimeType ?? "").lowercased()
                if mime.contains("mpegurl") || mime.contains("video/") || u.lowercased().contains(".m3u8") || u.lowercased().contains(".mp4") {
                    bridge.report(t: "net", u: u)
                }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onURL(webView.url?.absoluteString, webView.title)
            webView.evaluateJavaScript("window.__deepScan && window.__deepScan()", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "sniff" else { return }
            if let s = message.body as? String,
               let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                if let u = d["u"] as? String { bridge.report(t: "net", u: u) }
                if let lst = d["list"] as? [String] { bridge.reportList(lst) }
            }
        }
    }

    static let hookJS = """
    (function(){
      function send(o){ try{ window.webkit.messageHandlers.sniff.postMessage(JSON.stringify(o)); }catch(e){} }
      function clean(raw){ var k=raw.indexOf('http'); if(k>0){raw=raw.slice(k);} try{ return new URL(raw, document.baseURI).href; }catch(e){ return null; } }
      function scanText(t){ if(!t || t.length>400000){ return; }
        var re=/[^"'<> ]{0,250}m3u8[^"'<> ]{0,150}/g; var out=[]; var m;
        while((m=re.exec(t)) && out.length<12){ var x=clean(m[0]); if(x){ out.push(x); } }
        if(out.length){ send({t:'urls', list:out}); } }
      var seen={};
      function say(u){ if(!seen[u]){ seen[u]=1; send({t:'net', u:u}); } }
      var of=window.fetch;
      if(of){ window.fetch=function(){ var a=arguments; var p=of.apply(this,a); var uu=(a[0]&&a[0].url)||a[0]||'';
        try{ p.then(function(r){ r.clone().text().then(function(t){ if(t.indexOf('#EXTM3U')>-1){ say(r.url||uu); } scanText(t); }).catch(function(){}); }).catch(function(){}); }catch(e){}
        return p; }; }
      var oo=XMLHttpRequest.prototype.open, os=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open=function(m,u){ this.__u=u; return oo.apply(this,arguments); };
      XMLHttpRequest.prototype.send=function(){ var x=this; x.addEventListener('load',function(){ try{ var t=x.responseText||''; if(t.indexOf('#EXTM3U')>-1){ say(x.__u||location.href); } scanText(t); }catch(e){} }); return os.apply(this,arguments); };
      function videoScan(){ try{ var vs=document.querySelectorAll('video,source'); for(var i=0;i<vs.length;i++){ var src=vs[i].currentSrc||vs[i].src||''; if(src.indexOf('m3u8')>-1||src.indexOf('.mp4')>-1||src.indexOf('video_id=')>-1||src.indexOf('douyinvod')>-1){ say(src); } } }catch(e){} }
      function perfScan(){ try{ var es=performance.getEntriesByType('resource'); for(var i=0;i<es.length;i++){ var n=es[i].name||''; if(n.indexOf('douyinvod')>-1||n.indexOf('mime_type=video_mp4')>-1||n.indexOf('/video/tos/')>-1||n.indexOf('.m3u8')>-1||n.indexOf('.mp4')>-1){ say(n); } } }catch(e){} }
      window.__deepScan=function(){ try{ scanText(document.documentElement.innerHTML.slice(0,300000));
        var t=''; [].forEach.call(document.querySelectorAll('script'), function(s){ t+=s.textContent.slice(0,150000); }); scanText(t); videoScan(); perfScan(); }catch(e){} };
      setInterval(function(){ videoScan(); perfScan(); }, 3000);
      try{ var mo=new MutationObserver(function(){ videoScan(); }); mo.observe(document.documentElement||document, {childList:true, subtree:true}); }catch(e){}
    })();
    """
}
