import SwiftUI
import WebKit

// ===================== 🌐 浏览器嗅探：任意网页 → m3u8/mp4 候选 → 下载入库 =====================

@MainActor
final class SniffVM: ObservableObject {
    struct Snip: Identifiable {
        let id: String          // 完整 URL
        var kind: String        // "m3u8" / "mp4"
        var note = ""
        var frac = -1.0         // -1 未开始
        var done = false
        var downloaded = false
    }
    @Published var items: [Snip] = []
    @Published var pageURL = ""
    @Published var pageTitle = ""

    func add(_ url: String) {
        guard url.hasPrefix("http"), items.count < 40 else { return }
        let low = url.lowercased()
        if low.contains("m3u8") || low.contains(".mp4") {
            // 过滤明显非媒体
            for drop in [".js", ".css", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".woff", ".ico", ".webp", ".html"] where low.contains(drop) && !low.contains("m3u8") { return }
            if items.contains(where: { $0.id == url }) { return }
            let k = low.contains("m3u8") ? "m3u8" : "mp4"
            items.append(Snip(id: url, kind: k))
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

            SiteBrowser(bridge: bridge, onURL: { u, t in
                vm.pageURL = u ?? vm.pageURL
                if let t = t, !t.isEmpty { vm.pageTitle = t }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                Text("候选 \(vm.items.count) 个 —— 网页里点播放即可自动嗅取，也可点「重扫」")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                if vm.items.isEmpty {
                    Spacer()
                } else {
                    List {
                        ForEach($vm.items) { $s in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(s.kind == "m3u8" ? "HLS" : "MP4")
                                        .font(.caption2).bold()
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(s.kind == "m3u8" ? Color.purple.opacity(0.25) : Color.green.opacity(0.25))
                                        .foregroundStyle(s.kind == "m3u8" ? Color.purple : Color.green)
                                        .clipShape(Capsule())
                                    Text(s.id).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                    Spacer()
                                    if s.frac >= 0 {
                                        ProgressView(value: Double(min(max(s.frac, 0), 1)))
                                            .frame(width: 54).scaleEffect(0.8)
                                    }
                                }
                                if !s.note.isEmpty {
                                    Text(s.note).font(.caption2).foregroundStyle(s.downloaded ? Color.green : .secondary)
                                }
                                HStack(spacing: 14) {
                                    Button(s.downloaded ? "已入库" : "下载") { startDownload(s) }
                                        .disabled(s.downloaded || s.frac >= 0)
                                    Button("复制链接") { UIPasteboard.general.string = s.id }
                                    Button("播放试探") {
                                        if let v = VideoItem.fromURLString(s.id, kind: s.kind) { app.coverVideo = v }
                                    }
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 2)
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
        }
        .onAppear { bridge.vm = vm }
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
                    try await HLS.download(m3u8URLString: s.id, tok: tok, destRel: destRel) { frac, sps in
                        Task { @MainActor in
                            self.vm.update(s.id) { cur in
                                cur.frac = frac
                                cur.note = "\(Int(frac * 100))% · \(Naming.fmtSpeed(sps))"
                            }
                        }
                    }
                    vm.update(s.id) { $0.frac = 1; $0.done = true; $0.downloaded = true; $0.note = "已存入视频库(\(destRel))" }
                    app.refresh()
                } else {
                    let file = try await DouyinAPI.download(u) { frac, sps in
                        Task { @MainActor in
                            self.vm.update(s.id) { cur in
                                cur.frac = frac
                                cur.note = "\(Int(frac * 100))% · \(Naming.fmtSpeed(sps))"
                            }
                        }
                    }
                    if SavePaths.write(file, rel: destRel) {
                        try? FileManager.default.removeItem(at: file)
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

    func load(_ u: String) {
        guard let url = URL(string: u) else { return }
        webView?.load(URLRequest(url: url))
    }
    func deepScan() {
        webView?.evaluateJavaScript("window.__deepScan && window.__deepScan()", completionHandler: nil)
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
        w.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
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
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let resp = navigationResponse.response as? HTTPURLResponse,
               let u = resp.url?.absoluteString, !navigationResponse.isMainDocument {
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
        // 新窗口需求 → 直接本页加载
        func webView(_ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                     for action: WKNavigationAction, childWindow: WKWindowContext?) -> WKWebView? {
            if let u = action.request.url { webView.load(URLRequest(url: u)) }
            return nil
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
      function videoScan(){ try{ var vs=document.querySelectorAll('video,source'); for(var i=0;i<vs.length;i++){ var src=vs[i].currentSrc||vs[i].src||''; if(src.indexOf('m3u8')>-1||src.indexOf('.mp4')>-1){ say(src); } } }catch(e){} }
      window.__deepScan=function(){ try{ scanText(document.documentElement.innerHTML.slice(0,300000));
        var t=''; [].forEach.call(document.querySelectorAll('script'), function(s){ t+=s.textContent.slice(0,150000); }); scanText(t); videoScan(); }catch(e){} };
      setInterval(videoScan, 3000);
      try{ var mo=new MutationObserver(function(){ videoScan(); }); mo.observe(document.documentElement||document, {childList:true, subtree:true}); }catch(e){}
    })();
    """
}
