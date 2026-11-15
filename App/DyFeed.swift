import SwiftUI
import WebKit
import AVFoundation

// MARK: - 抖音模式 v2（B+ 方案）
// 天线：隐藏 WKWebView 后台开抖音推荐页，JS 抄 DOM 里的视频卡片（登录态由页面自带）
// 播放：盒子原生竖滑流；刷=分享页免费直链(0配额)，♥存=多平台API无水印原画(1次/条)

struct DyItem: Identifiable, Hashable {
    let id: String
    var desc: String
    var cover: String
    var playURL: URL?
    var saved = false
}

enum DyAntennaJS {
    static let reporter = """
    (() => {
      if (window.__box_dy_on) return;
      window.__box_dy_on = true;
      const seen = new Set();
      const scan = () => {
        const out = [];
        const add = (id, d, c) => {
          if (!id || id.length < 15 || seen.has(id)) return;
          seen.add(id);
          out.push({ id: id, d: (d || '').slice(0, 80), c: c || '' });
        };
        // 通道1：标准链接卡片
        for (const a of document.querySelectorAll('a[href]')) {
          const m = (a.getAttribute('href') || '').match(/\\/(?:video|note)\\/(\\d{15,25})/);
          if (!m) continue;
          const card = (a.closest && a.closest('li,div')) || a;
          const img = card.querySelector ? card.querySelector('img') : null;
          add(m[1], (a.textContent || '').trim(), img ? (img.currentSrc || img.src || '') : '');
        }
        // 通道2：页面内嵌数据（SSR 的 RENDER_DATA 是 URL 编码的，先解码再捞）
        let html = document.documentElement.innerHTML;
        const rd = document.getElementById('RENDER_DATA');
        let hay = html;
        if (rd && rd.textContent) { try { hay = decodeURIComponent(rd.textContent) + "\\n" + html; } catch (e) {} }
        const re = /"aweme_id":"(\\d{15,25})"(.{0,3000}?)(?="aweme_id"|$)/gs;
        let mm;
        while ((mm = re.exec(hay)) !== null) {
          const seg = mm[2] || '';
          const dm = seg.match(/"desc":"([^"]{1,90})"/);
          const cm = seg.match(/"url_list":\\["(https:[^"]{1,300})"/);
          add(mm[1], dm ? dm[1] : '', cm ? cm[1].replace(/\\u0026/g, '&') : '');
          if (out.length > 40) break;
        }
        if (out.length) window.webkit.messageHandlers.boxdy.postMessage(JSON.stringify(out));
      };
      scan();
      const authPing = () => {
        const t = document.body ? (document.body.innerText || '') : '';
        const notLogged = /扫码登录|手机号登录|登录抖音/.test(t);
        window.webkit.messageHandlers.boxdyauth.postMessage(notLogged ? '0' : '1');
      };
      authPing();
      setInterval(() => {
        scan();
        authPing();
        if ((window.innerHeight + window.scrollY) > document.body.scrollHeight - innerHeight * 1.5) {
          window.scrollBy(0, innerHeight);
        }
      }, 2500);
    })();
    """
}

// 免费播放地址提取（分享页 JSON：play_addr.url_list 或 video_id 走 snssdk 302 老口）
enum DyShare {
    static func extract(_ html: String) -> URL? {
        // 路线1：play_addr url_list 首个 https
        if let r = html.range(of: "\"play_addr\"") {
            let rest = html[r.upperBound...].replacingOccurrences(of: "\\/", with: "/")
            if let h = rest.range(of: "https://") {
                let tail = rest[h.lowerBound...]
                if let e = tail.firstIndex(of: "\"") {
                    var s = String(tail[..<e]).replacingOccurrences(of: "\\u0026", with: "&")
                    if s.contains("playwm") { s = s.replacingOccurrences(of: "playwm", with: "play") }
                    if let u = URL(string: s) { return u }
                }
            }
        }
        // 路线2：video_id → snssdk play 接口（302 免签老口）
        if let r = html.range(of: "\"video_id\":\"") {
            let rest = html[r.upperBound...]
            if let e = rest.firstIndex(of: "\"") {
                let vid = String(rest[..<e])
                return URL(string: "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(vid)&ratio=1080p&line=0")
            }
        }
        return nil
    }
}

@MainActor
final class DyFeedModel: NSObject, ObservableObject {
    @Published var items: [DyItem] = []
    @Published var status = "正在连接抖音…"
    @Published var index = 0
    var web: WKWebView = {
        let cfg = WKWebViewConfiguration()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        return w
    }()
    private var started = false
    private var appRef: AppState?
    @Published var loggedIn = false
    private var forcedRecommend = false

    func goRecommend() {
        web.evaluateJavaScript("location.href='https://www.douyin.com/?recommend=1'", completionHandler: nil)
    }

    func retryIfEmpty() {
        if started, items.isEmpty { web.reload() }
    }

    func start(app: AppState) {
        appRef = app
        guard !started else { return }
        started = true
        web.configuration.userContentController.add(self, name: "boxdy")
        web.configuration.userContentController.add(self, name: "boxdyauth")
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "https://www.douyin.com/?recommend=1")!))
        status = "天线展开中，等卡片飘来…"
    }

    func ensurePlay(_ idx: Int, _ then: @escaping @Sendable () -> Void) {
        guard items.indices.contains(idx), items[idx].playURL == nil else {
            then()
            return
        }
        let id = items[idx].id
        Task { @MainActor in
            var req = URLRequest(url: URL(string: "https://www.iesdouyin.com/share/video/\(id)")!)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let html = String(data: data, encoding: .utf8),
               let u = DyShare.extract(html),
               items.indices.contains(idx) {
                items[idx].playURL = u
            }
            then()
        }
    }

    // 兜底：花 1 次配额解析可播直链（免费线路失败时手动救）
    func apiPlay(_ item: DyItem, done: @escaping @Sendable (URL?) -> Void) {
        Task { @MainActor in
            guard let r = try? await ParseRouter.parse(link: "https://www.douyin.com/video/\(item.id)"),
                  let o = r.options.first else { done(nil); return }
            done(o.url)
        }
    }

    func save(_ item: DyItem, ok: @escaping @Sendable (String) -> Void, fail: @escaping @Sendable (String) -> Void) {
        guard let app = appRef else { fail("引擎未就绪"); return }
        app.keepAlive.start()
        Task { @MainActor in
            defer { app.keepAlive.stop() }
            do {
                let r = try await ParseRouter.parse(link: "https://www.douyin.com/video/\(item.id)")
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
                    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].saved = true }
                    ok(String(r.title.prefix(40)))
                } else { throw NSError(domain: "dy", code: 3) }
            } catch {
                fail(String("\(error)".prefix(50)))
            }
        }
    }
}

// MARK: 天线桥（DOM 抄写员上报 + 页面加载后注入）
extension DyFeedModel: WKNavigationDelegate, WKScriptMessageHandler {
    @objc(webView:didFinishNavigation:)
    func webView(_ sv: WKWebView, didFinish nav: WKNavigation!) {
        sv.evaluateJavaScript(DyAntennaJS.reporter, completionHandler: nil)
    }
    nonisolated func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        if msg.name == "boxdyauth" {
            let on = ((msg.body as? String) ?? "") == "1"
            DispatchQueue.main.async {
                if on {
                    if !self.loggedIn {
                        self.loggedIn = true
                        self.status = "已登录 ✓ 抄写员工作中…"
                        // 登录态确认后若不在推荐流，抽一鞭子（仅首次）
                        if !self.forcedRecommend {
                            self.forcedRecommend = true
                            if !(self.web.url?.absoluteString.contains("recommend") ?? false) {
                                self.goRecommend()
                            }
                        }
                    }
                } else if self.loggedIn {
                    self.loggedIn = false
                    self.status = "未检测到登录态（点左上展开天线登录）"
                } else {
                    self.status = "天线页面加载中…"
                }
            }
            return
        }
        guard msg.name == "boxdy", let s = msg.body as? String,
              let d = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return }
        DispatchQueue.main.async {
            var fresh: [DyItem] = []
            for o in arr {
                guard let id = o["id"] else { continue }
                if self.items.contains(where: { $0.id == id }) { continue }
                fresh.append(DyItem(id: id, desc: o["d"] ?? "", cover: o["c"] ?? "", playURL: nil))
            }
            if !fresh.isEmpty {
                self.items.append(contentsOf: fresh)
                self.status = "已收录 \(self.items.count) 条"
            }
        }
    }
}

// 天线页面宿主：同一个 WKWebView 挪进界面（高度可调），进了 window 懒加载才会醒
struct AntennaHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ v: UIView, context: Context) {
        guard web.superview !== v else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            web.topAnchor.constraint(equalTo: v.topAnchor),
            web.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
    }
}

// MARK: - 原生竖滑流界面（播放器单例挂底层，格子只画封面）

struct DyFeedView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var feed = DyFeedModel()
    @StateObject private var pc = PlayerController()
    @State private var busySave = false
    @State private var toast = ""
    @State private var showAntenna = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: pc.player, fill: true)
                .ignoresSafeArea()

            // 天线实况窗：展开可登录/过验证码/看页面真身，收起只剩 2pt
            AntennaHost(web: feed.web)
                .frame(maxWidth: .infinity)
                .frame(height: showAntenna ? 400 : 2)
                .clipped()
                .overlay(alignment: .bottom) {
                    if showAntenna {
                        Text("登录/验证码在这块里直接操作，搞定后点左上收起").font(.caption2)
                            .foregroundStyle(.white).padding(6)
                            .background(Color.black.opacity(0.55))
                    }
                }
                .animation(.spring(duration: 0.3), value: showAntenna)
                .zIndex(10)

            if feed.items.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(feed.status).font(.subheadline).foregroundStyle(.secondary)
                    Text("点左上『天线』展开网页：在里面扫码登录或点验证码，搞定后收起即可")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 14) {
                        if !feed.loggedIn {
                            NavigationLink {
                                BoxBrowserView(seed: "https://www.douyin.com/?recommend=1")
                            } label: {
                                Text("去登录").font(.callout)
                                    .padding(.horizontal, 18).padding(.vertical, 9)
                                    .background(Capsule().fill(.tint.opacity(0.85)))
                                    .foregroundStyle(.white)
                            }
                        } else {
                            Text("已登录 ✓ 正在抄卡，稍安勿躁…").font(.callout).foregroundStyle(.green)
                        }
                        Button("重试天线") { feed.retryIfEmpty() }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                TabView(selection: $feed.index) {
                    ForEach(Array(feed.items.enumerated()), id: \.element.id) { i, it in
                        DyCell(it: it, pc: pc).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            if !pc.playing && !feed.items.isEmpty {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 60))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 6)
            }

            VStack { Spacer(minLength: 40); controlRail }
            if !toast.isEmpty {
                VStack { Spacer(); toastBubble.padding(.bottom, 110) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showAntenna.toggle() } label: {
                    Image(systemName: feed.loggedIn ? "antenna.radiowaves.left.and.right" : "exclamationmark.antenna.radiowaves.left.and.right")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(feed.loggedIn ? .green : .orange)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("回推荐流") { feed.goRecommend() }
                    Button("抄我喜欢页（收藏搬运）") {
                        feed.web.evaluateJavaScript("location.href='https://www.douyin.com/user/self?tab=like'", completionHandler: nil)
                    }
                    Button("刷新天线") { feed.web.reload() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            feed.start(app: app)
            playCurrent()
        }
        .onChange(of: feed.index) { _ in playCurrent() }
    }

    private func playCurrent() {
        let i = feed.index
        feed.ensurePlay(i) {
            Task { @MainActor in
                guard feed.items.indices.contains(i), let u = feed.items[i].playURL else { return }
                pc.load(u, id: "dy_\(i)")
            }
        }
    }

    private var controlRail: some View {
        HStack(spacing: 18) {
            Spacer()
            VStack(spacing: 16) {
                Button {
                    guard let it = current(), !busySave else { return }
                    busySave = true
                    feed.apiPlay(it, done: { u in
                        Task { @MainActor in
                            busySave = false
                            if let u, let i = feed.items.firstIndex(where: { $0.id == it.id }) {
                                feed.items[i].playURL = u
                                pc.load(u, id: "dyapi_\(it.id)")
                                flash("解析成功，已切原画线路（耗1次配额）")
                            } else { flash("这条解析也失败了") }
                        }
                    })
                } label: {
                    Image(systemName: "wand.and.stars").font(.title2)
                        .foregroundStyle(busySave ? Color.secondary : Color.orange).shadow(radius: 4)
                }
                .disabled(busySave)
                Button {
                    guard let it = current(), !busySave else { return }
                    busySave = true
                    feed.save(it,
                              ok: { t in flash("已入库：\(t)") },
                              fail: { e in flash("存库失败 \(e)") })
                } label: {
                    Image(systemName: (current()?.saved ?? false) ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.title).foregroundStyle(.white).shadow(radius: 4)
                }
                .disabled(busySave)
                if busySave { ProgressView().tint(.white) }
            }
            .padding(.trailing, 14)
        }
    }

    private var toastBubble: some View {
        Text(toast).font(.callout).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.6)))
    }

    private func flash(_ s: String) {
        busySave = false
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { toast = "" }
    }

    private func current() -> DyItem? {
        feed.items.indices.contains(feed.index) ? feed.items[feed.index] : nil
    }
}

struct DyCell: View {
    let it: DyItem
    @ObservedObject var pc: PlayerController
    var body: some View {
        ZStack {
            if it.playURL == nil {
                AsyncImage(url: URL(string: it.cover)) { im in
                    im.resizable().scaledToFill()
                } placeholder: { Color.gray.opacity(0.15) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(ProgressView().tint(.white))
            } else {
                Color.clear
            }
            VStack {
                Spacer()
                Text(it.desc)
                    .font(.subheadline).foregroundStyle(.white)
                    .shadow(radius: 3)
                    .padding(.horizontal).padding(.bottom, 26)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pc.togglePlay() }
    }
}
