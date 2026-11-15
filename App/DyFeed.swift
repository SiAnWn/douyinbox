import SwiftUI
import WebKit
import AVFoundation

// MARK: - 抖音皮肤模式 v3（网页自滑 + 内嵌播放根治 + URL 取 id 存原画）
// 现实：移动 UA 的 douyin 推荐流本身就是整屏上滑沉浸 UI，手感现成；
// 唯一病灶 = 视频缺 playsinline，WKWebView 每条都弹系统全屏播放器。根治即可。

enum DySkinJS {
    // playsinline 根治：已有视频秒补 + 新建视频秒盯 + 弹全屏秒摁回
    static let inlinePatch = """
    (() => {
      if (window.__boxInline) return;
      window.__boxInline = true;
      // 1) 出生证拦截：所有新建 video 自带 playsinline（抢在开播前）
      const orig = document.createElement.bind(document);
      document.createElement = function (tag, opts) {
        const el = orig(tag, opts);
        if (String(tag).toLowerCase() === 'video') {
          el.setAttribute('playsinline', '');
          el.setAttribute('webkit-playsinline', '');
        }
        return el;
      };
      // 2) 废掉全屏入口：进全屏一律摁回 inline
      const p = HTMLVideoElement.prototype;
      try {
        p.webkitEnterFullscreen = function () {
          try { this.webkitSetPresentationMode('inline'); } catch (e) {}
        };
        p.webkitEnterFullScreen = p.webkitEnterFullscreen;
        const rq = p.requestFullscreen;
        p.requestFullscreen = function () { try { this.webkitSetPresentationMode('inline'); } catch (e) {} return Promise.resolve(); };
        p.webkitRequestFullscreen = function () {};
        void rq;
      } catch (e) {}
      // 3) 存量视频补刀 + 变异监视 + 轮询兜底
      const fixOne = (v) => {
        v.setAttribute('playsinline', '');
        v.setAttribute('webkit-playsinline', '');
        try { if (v.webkitSetPresentationMode && v.webkitPresentationMode !== 'inline') v.webkitSetPresentationMode('inline'); } catch (e) {}
        if (!v.__boxhook) {
          v.__boxhook = 1;
          v.addEventListener('webkitpresentationmodechanged', () => {
            try { if (v.webkitPresentationMode !== 'inline') v.webkitSetPresentationMode('inline'); } catch (e) {}
          }, true);
        }
      };
      const fix = () => document.querySelectorAll('video').forEach(fixOne);
      fix();
      new MutationObserver(fix).observe(document.documentElement, { childList: true, subtree: true });
      setInterval(fix, 2000);
      // 皮肤 CSS：保守版
      if (!document.getElementById('box-skin')) {
        const s = document.createElement('style'); s.id = 'box-skin';
        s.textContent = `
          video { object-fit: cover !important; }
          body { background: #000 !important; }
          ::-webkit-scrollbar { width: 0 !important; }
        `;
        document.documentElement.appendChild(s);
      }
    })();
    """
    // 取当前视频 id：URL 优先（点进详情页必带），滚流中兜底找最近链接
    static let extractId = """
    (() => {
      const m = location.href.match(/\\/(?:video|note)\\/(\\d{15,25})/);
      if (m) return m[1];
      for (const a of document.querySelectorAll('a[href]')) {
        const mm = (a.getAttribute('href') || '').match(/\\/(?:video|note)\\/(\\d{15,25})/);
        if (mm) return mm[1];
      }
      const re = /"aweme_id":"(\\d{15,25})"/;
      const rd = document.getElementById('RENDER_DATA');
      if (rd && rd.textContent) { try { const j = decodeURIComponent(rd.textContent); const g = j.match(re); if (g) return g[1]; } catch (e) {} }
      const g = document.documentElement.innerHTML.match(/"aweme_id":"(\\d{15,25})"/);
      return g ? g[1] : '';
    })()
    """
}

@MainActor
final class DySkinModel: NSObject, ObservableObject {
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var busySave = false
    @Published var toast = ""
    let web: WKWebView

    private var appRef: AppState?
    private var progObs: NSKeyValueObservation?
    private var reloadTries = 0

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.userContentController.addUserScript(WKUserScript(script: DySkinJS.inlinePatch,
                                                             injectionTime: .atDocumentStart,
                                                             forMainFrameOnly: true))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height), configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        progObs = web.observe(\.estimatedProgress, options: [.new]) { w, _ in
            DispatchQueue.main.async { self.progress = w.estimatedProgress }
        }
    }

    func start(app: AppState) {
        appRef = app
        if web.url == nil {
            web.load(URLRequest(url: URL(string: "https://www.douyin.com/?recommend=1")!))
        }
    }

    func go(_ url: String) { web.load(URLRequest(url: URL(string: url)!)) }
    func reload() { web.reload() }

    // 存当前视频：无水印原画管线
    func saveCurrent() {
        guard let app = appRef, !busySave else { return }
        busySave = true
        web.evaluateJavaScript(DySkinJS.extractId) { res, _ in
            let id = (res as? String) ?? ""
            DispatchQueue.main.async { self.doSave(id, app: app) }
        }
    }

    private func doSave(_ id: String, app: AppState) {
        guard id.count > 14 else {
            busySave = false
            flash("没找到视频 id（点进视频页再存）")
            return
        }
        app.keepAlive.start()
        Task { @MainActor in
            defer { app.keepAlive.stop(); self.busySave = false }
            do {
                let r = try await ParseRouter.parse(link: "https://www.douyin.com/video/\(id)")
                guard let o = r.options.first else { throw NSError(domain: "dy", code: 1) }
                let file = try await DouyinAPI.download(o.url) { _, _ in }
                let sz = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
                guard sz >= 30_000 else {
                    try? FileManager.default.removeItem(at: file)
                    throw NSError(domain: "dy", code: 2)
                }
                let name = Naming.fileName(r.author, r.title, o)
                if SavePaths.write(file, rel: name) {
                    DownloadStore.set(o.url.absoluteString, name)
                    app.refresh()
                    BoxIsland.banner("百宝箱 · 抖音存库", "\(String(r.title.prefix(40))) 已入库")
                    flash("已入库 ✓")
                } else { throw NSError(domain: "dy", code: 3) }
            } catch {
                self.flash("存库失败 \(String("\(error)".prefix(50)))")
            }
        }
    }

    func flash(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.toast = "" }
    }
}

// Xcode26 委托坑：全套显式遵循 + 钉选择器
extension DySkinModel: WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @objc func webView(_ sv: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
        loading = true
    }
    @objc(webView:didFinishNavigation:)
    func webView(_ sv: WKWebView, didFinish nav: WKNavigation!) {
        loading = false; progress = 0
        sv.evaluateJavaScript(DySkinJS.inlinePatch, completionHandler: nil)
        // 自愈：5 秒后页面若还是死的（没视频没文字）就重开一次，最多自愈两次
        reloadTries += 1
        if reloadTries <= 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                sv.evaluateJavaScript("document.querySelectorAll('video').length + (document.body.innerText||'').length") { r, _ in
                    let vital = (r as? NSNumber)?.doubleValue ?? 0
                    if vital < 30, self.reloadTries <= 2 {
                        self.reloadTries += 10   // 限流：自愈只留一次机会
                        sv.reload()
                    }
                }
            }
        }
    }
    @objc func webView(_ sv: WKWebView, decidePolicyFor su: WKNavigationAction,
                       decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = su.request.url, let s = u.scheme?.lowercased(), s.hasPrefix("http") {
            decisionHandler(.allow)
        } else {
            if let u = su.request.url { UIApplication.shared.open(u) }
            decisionHandler(.cancel)
        }
    }
    @objc func webView(_ sv: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                       for su: WKNavigationAction, message: WKScriptMessage?) -> WKWebView? {
        sv.load(su.request)
        return nil
    }
    @objc(userContentController:didReceiveScriptMessage:)
    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {}
}

struct DySkinHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 界面：整屏网页 + 浮动存取键

struct DyFeedView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var m = DySkinModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.ignoresSafeArea()
            DySkinHost(web: m.web)
                .ignoresSafeArea()
            if m.loading {
                VStack { ProgressView(value: min(m.progress, 0.97)).progressViewStyle(.linear); Spacer() }
                    .ignoresSafeArea()
            }
            Button { m.saveCurrent() } label: {
                ZStack {
                    Circle().fill(.black.opacity(0.55)).frame(width: 52, height: 52)
                    if m.busySave { ProgressView().tint(.white) }
                    else { Image(systemName: "tray.and.arrow.down").font(.title3).foregroundStyle(.green) }
                }
                .shadow(radius: 5)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 26)
            if !m.toast.isEmpty {
                VStack { Spacer(); Text(m.toast).font(.callout).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.bottom, 90) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("推荐流") { m.go("https://www.douyin.com/?recommend=1") }
                    Button("精选流") { m.go("https://www.douyin.com/jingxuan") }
                    Button("我的喜欢") { m.go("https://www.douyin.com/user/self?tab=like") }
                    Button("刷新") { m.reload() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { m.start(app: app) }
    }
}
