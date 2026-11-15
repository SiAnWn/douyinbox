import SwiftUI
import WebKit
import Photos

// MARK: - 内置浏览器 v1（裸需求版：能逛、能存、能记路）
// 引擎 = 系统 Safari 同一颗（WKWebView），UA 保持系统默认（本身即移动版 Safari 串）

@MainActor
final class BrowserModel: NSObject, ObservableObject,
                          WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var canBack = false
    @Published var canFwd = false
    @Published var currentURL = ""
    @Published var longPressImage: String?
    // Safari 式：滚动收起工具栏
    @Published var barsShown = true
    private var lastOffY: CGFloat = 0

    let web: WKWebView

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // 不伪装、不改 UA —— 网站看到的就是一台真 iPhone Safari
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        cfg.userContentController.add(self, name: "boxlong")
        web.allowsBackForwardNavigationGestures = true   // 右滑返回，浏览器基本礼貌
        web.addObserver(self, forKeyPath: "estimatedProgress", options: [.new], context: nil)
        web.scrollView.addObserver(self, forKeyPath: "contentOffset", options: [.new, .old], context: nil)
        web.scrollView.contentInset = UIEdgeInsets(top: 46, left: 0, bottom: 56, right: 0)
        // 广告拦截：系统级内容规则，编译一次，之后所有加载走它
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "boxAdsV1",
            encodedContentRuleList: BoxAdRules.json
        ) { list, _ in
            guard let list else { return }
            DispatchQueue.main.async { cfg.userContentController.add(list) }
        }
    }

    func go(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains(".") || s.contains(" ") {
            // 不像域名就当搜索
            let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            s = "https://www.bing.com/search?q=" + enc
        }
        if !s.hasPrefix("http") { s = "https://" + s }
        if let u = URL(string: s) { web.load(URLRequest(url: u)) }
    }

    // JS：长按时把命中的图片 src 递给原生
    private let longJS = """
    document.addEventListener('contextmenu', e => {
      let src = null, el = e.target;
      if (el && el.tagName === 'IMG') src = el.currentSrc || el.src;
      if (!src && el && el.closest) {
        const a = el.closest('a'); const im = a && a.querySelector('img');
        if (im) src = im.currentSrc || im.src;
      }
      if (src) { try { src = new URL(src, location.href).href; } catch (x) {} window.webkit.messageHandlers.boxlong.postMessage(String(src)); }
    }, true);
    """

    private func refreshState() {
        DispatchQueue.main.async {
            self.canBack = self.web.canGoBack
            self.canFwd = self.web.canGoForward
            self.currentURL = self.web.url?.absoluteString ?? ""
        }
    }

    // 存图：带 referer 抓原图 → 相册
    func saveImage(_ src: String) {
        guard let u = URL(string: src) else { return }
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let r = web.url?.deletingPathExtension().absoluteString { req.setValue(r, forHTTPHeaderField: "Referer") }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let d = data, !d.isEmpty else { return }
            let tmp = NSTemporaryDirectory() + "bx_" + UUID().uuidString + (src.hasSuffix(".png") ? ".png" : ".jpg")
            guard (try? d.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
                guard st == .authorized || st == .limited else { return }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: URL(fileURLWithPath: tmp))
                }
            }
        }.resume()
    }

    // MARK: delegates（Xcode26 协议 Swift 名 = ObjC 全称，逐一贴齐）
    @objc func webView(_ sv: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
        loading = true
        if !barsShown { setBars(true) }   // 跳新页就把工具栏叫回来
        refreshState()
    }
    @objc(webView:didFinishNavigation:)
    func webView(_ sv: WKWebView, didFinish nav: WKNavigation!) {
        loading = false; progress = 0; refreshState()
        sv.evaluateJavaScript(longJS, completionHandler: nil)
    }
    @objc func webView(_ sv: WKWebView, didFail nav: WKNavigation!, withError e: Error) {
        loading = false; refreshState()
    }
    override func observeValue(forKeyPath k: String?, of o: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if k == "estimatedProgress" { progress = web.estimatedProgress }
        if k == "contentOffset", let ch = change {
            let new = (ch[.newKey] as? NSValue)?.cgPointValue ?? CGPoint(x: 0, y: lastOffY)
            let dy = new.y - lastOffY
            lastOffY = new.y
            if abs(dy) > 3 {
                let want = dy < 0 || new.y < 20          // 上滑或已在顶部 → 露出工具栏
                if want != barsShown { setBars(want) }
            }
        }
    }

    private func setBars(_ shown: Bool) {
        barsShown = shown
        UIView.animate(withDuration: 0.22) {
            let ins = self.web.scrollView.contentInset
            self.web.scrollView.contentInset = UIEdgeInsets(top: shown ? 46 : 0, left: ins.left,
                                                            bottom: shown ? 56 : 0, right: ins.right)
        }
    }
    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func webView(_ sv: WKWebView, decidePolicyFor su: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = su.request.url, let scheme = u.scheme?.lowercased(), scheme.hasPrefix("http") {
            decisionHandler(.allow)
        } else {
            // weixin://、tbopen:// 这种 App 协议跳出去，不在浏览器里死磕
            if let u = su.request.url { UIApplication.shared.open(u) }
            decisionHandler(.cancel)
        }
    }
    // target=_blank 的窗口请求：留在本窗（图站翻页常用）
    @objc(webView:createWebViewWithConfiguration:forNavigationAction:message:)
    func webView(_ sv: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for su: WKNavigationAction, message: WKScriptMessage?) -> WKWebView? {
        sv.load(su.request)
        return nil
    }
    @objc(userContentController:didReceiveScriptMessage:)
    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        if msg.name == "boxlong", let s = msg.body as? String {
            DispatchQueue.main.async { self.longPressImage = s }
        }
    }
}

// MARK: - 广告规则（引擎级拦截：域名黑名单 + 常见广告元素隐藏）
enum BoxAdRules {
    static let json = #"""
    [
      {"trigger":{"url-filter":"googlesyndication\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googleadservices\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googletagmanager\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googletagservices\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"doubleclick\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adservice\\.google\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"google-analytics\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"amazon-adsystem\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adnxs\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"rubiconproject\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"pubmatic\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"openx\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"criteo"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"taboola\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"outbrain\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"moatads\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"scorecardresearch\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"quantserve\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"cnzz\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"51\\.la"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"umeng\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"hm\\.baidu\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"gdt\\.qq\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"exoclick\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"exdynsrv\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"trafficjunky\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adsterra\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"a-ads\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popads\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"videoadex\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"reacheasing\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"plytix\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"updtnvpl\\.info"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adsafety\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"magsrv\\.com"},"action":{"type":"block"}},
      {"trigger":{},"action":{"type":"css-display-none","selector":".ad, .ads, .ad-banner, .adbox, .advert, .sponsor, .sponsored, #ad, #ads, #banner, .popbox, .popunder, .floating-ads, .mobile-pop, iframe[src*='adsystem'], iframe[src*='exoclick'], iframe[src*='trafficjunky']"}}
    ]
    """#
}

// MARK: - WKWebView 宿主（复用同一实例，滚动/历史不断）
struct WebViewHost: UIViewRepresentable {
    let m: BrowserModel
    func makeUIView(context: Context) -> WKWebView { m.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 书签（速达架）
struct BoxBookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
}
enum BoxBookmarkStore {
    static let key = "boxBookmarksV1"
    static func all() -> [BoxBookmark] {
        if let d = UserDefaults.standard.data(forKey: key),
           let l = try? JSONDecoder().decode([BoxBookmark].self, from: d) { return l }
        // 出厂三发（都是实测活着的规则站）
        return [BoxBookmark(name: "WildSkirts", url: "https://www.wildskirts.com/"),
                BoxBookmark(name: "PutMega", url: "https://putmega.com/"),
                BoxBookmark(name: "Kemono", url: "https://kemono.cr/")]
    }
    static func save(_ l: [BoxBookmark]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func addCurrent(name: String, url: String) {
        var l = all()
        guard !l.contains(where: { $0.url == url }), !url.isEmpty else { return }
        l.insert(BoxBookmark(name: name.isEmpty ? url : name, url: url), at: 0)
        save(l)
    }
}

// MARK: - 主界面
struct BoxBrowserView: View {
    @StateObject private var m = BrowserModel()
    @State private var input = ""
    @State private var showBookmarks = false
    @State private var bookName = ""

    var body: some View {
        ZStack(alignment: .top) {
            WebViewHost(m: m)
                .ignoresSafeArea()

            // 顶栏（地址+搜索）：下滑收起，上滑即回，Safari 同款
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                TextField("地址 / 搜索", text: $input)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { m.go(input); input = "" }
                if m.loading {
                    Button { m.web.stopLoading() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                } else {
                    Button { showBookmarks = true } label: { Image(systemName: "book") }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 10)
            .opacity(m.barsShown ? 1 : 0)
            .offset(y: m.barsShown ? 0 : -70)
            .animation(.spring(duration: 0.25), value: m.barsShown)

            VStack { Spacer(); bottomBar }
            if m.loading {
                VStack { ProgressView(value: min(m.progress, 0.97)).progressViewStyle(.linear); Spacer() }
            }
        }
        .navigationTitle("浏览器")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("这张图", isPresented: Binding(
            get: { m.longPressImage != nil },
            set: { if !$0 { m.longPressImage = nil } }),
            titleVisibility: .hidden) {
            Button("存入相册") { if let s = m.longPressImage { m.saveImage(s) } }
            Button("复制直链") {
                if let s = m.longPressImage { UIPasteboard.general.string = s }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showBookmarks) { bookmarksSheet }
    }

    private var bottomBar: some View {
        HStack(spacing: 34) {
            Button { m.web.goBack() } label: { Image(systemName: "chevron.backward") }.disabled(!m.canBack)
            Button { m.web.goForward() } label: { Image(systemName: "chevron.forward") }.disabled(!m.canFwd)
            Button { m.web.reload() } label: { Image(systemName: "arrow.clockwise") }
            Button { BoxBookmarkStore.addCurrent(name: m.web.title ?? "", url: m.currentURL) } label: { Image(systemName: "bookmark.plus") }
                .disabled(m.currentURL.isEmpty)
            Spacer()
            Menu {
                Button("在 Safari 打开") {
                    if let u = m.web.url { UIApplication.shared.open(u) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .font(.title3)
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
        .opacity(m.barsShown ? 1 : 0)
        .offset(y: m.barsShown ? 0 : 96)
        .animation(.spring(duration: 0.25), value: m.barsShown)
    }

    private var bookmarksSheet: some View {
        NavigationStack {
            List {
                ForEach(BoxBookmarkStore.all()) { b in
                    Button { m.go(b.url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name).font(.subheadline)
                            Text(b.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { idx in
                    var l = BoxBookmarkStore.all()
                    l.remove(atOffsets: idx)
                    BoxBookmarkStore.save(l)
                }
            }
            .overlay {
                if BoxBookmarkStore.all().isEmpty {
                    ContentUnavailableView("书签是空的", systemImage: "book",
                                           description: Text("逛到好站点点下面那枚加号"))
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showBookmarks = false }
                }
            }
        }
    }
}
