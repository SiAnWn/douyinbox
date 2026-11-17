import SwiftUI
import WebKit

// ===================== 🤖 整剧 1080 自动补漏流水线 =====================
// 人工只点一次钮：逐集开剧集页(桌面登录态) → 嗅本集流 → 验货 → 入库 → 喘息
// 复用嗅探器的候选管道(SniffVM.add 去重/打标/拒加密档)，全程带日志

@MainActor
final class SniffAutoVM: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let num: Int
        let title: String
        var state = "排队"     // 排队/嗅流…/下载…/✓入库/✓已有/✗未抓到/✗下载败/⏸暂停
    }
    @Published var rows: [Row] = []
    @Published var hint = ""
    @Published var logs: [String] = []
    @Published var running = false
    let cand = SniffVM()          // 候选管道复用
    var stop = false
    weak var agent: SniffAgent?
    private var job: Task<Void, Never>?

    func log(_ s: String) {
        let t = Int(Date().timeIntervalSince1970) % 86400
        logs.append(String(format: "[%02d:%02d:%02d] ", t / 3600, (t / 60) % 60, t % 60) + s)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
    func setRow(_ i: Int, _ st: String) {
        if i < rows.count { rows[i].state = st }
    }

    func start(eps: [MixEpisode], base: String, folder: String, mixID: String) {
        guard !running else { return }
        guard let agent = agent else { hint = "演员未就位(重试或退出重进)"; return }
        running = true; stop = false
        rows = eps.map { Row(id: $0.id, num: $0.num, title: $0.title) }
        hint = "流水线启动…"
        job = Task { @MainActor in
            var got = 0, have = 0, miss = 0
            for (i, ep) in eps.enumerated() {
                if stop { setRow(i, "⏸暂停"); break }
                let rel = "\(base)/\(folder)/\(Naming.epName(num: ep.num, title: ep.title))"
                if SavePaths.exists(rel: rel) { setRow(i, "✓已有"); have += 1; continue }
                setRow(i, "嗅流…")
                cand.items = []
                cand.currentVid = ep.id
                cand.currentFileVid = ""
                agent.load("https://www.douyin.com/video/\(ep.id)", into: cand)
                var picked: SniffVM.Snip?
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if stop { break }
                    if let m = cand.items.first(where: {
                        $0.kind == "mp4" && ($0.id.lowercased().contains(ep.id)
                            || SniffVM.qvStatic($0.id.lowercased(), "video_id") == cand.currentFileVid)
                    }) { picked = m; break }
                }
                // 兜底：播放器本集先请求，第一条 mp4 大概率就是它
                if picked == nil { picked = cand.items.first { $0.kind == "mp4" } }
                guard let snip = picked else {
                    setRow(i, "✗未抓到"); miss += 1
                    log("EP\(ep.num) 20s 未嗅到 → 缺集登记")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                setRow(i, "下载… \(snip.tag)")
                do {
                    let file = try await autoFetch(snip.id) { frac in
                        Task { @MainActor in self.setRow(i, "下载…\(Int(frac * 100))%") }
                    }
                    if SavePaths.write(file, rel: rel) {
                        try? FileManager.default.removeItem(at: file)
                        MixManifest.record(mixID, epID: ep.id, rel: rel)
                        setRow(i, "✓入库 \(snip.tag.isEmpty ? "mp4" : snip.tag)"); got += 1
                        log("EP\(ep.num) ✓入库 \(rel)")
                    } else {
                        try? FileManager.default.removeItem(at: file)
                        setRow(i, "✗写库败"); miss += 1
                        log("EP\(ep.num) 写库失败")
                    }
                } catch {
                    setRow(i, "✗下载败"); miss += 1
                    log("EP\(ep.num) 下载失败: \(error.localizedDescription)")
                }
                // 节奏：5~9 秒喘息；每 20 集歇 1 分钟压风控
                if i > 0 && i % 20 == 19 {
                    hint = "已连续 \(i + 1) 集，歇 60 秒压节奏…"
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
                let jitter = UInt64(5_000_000_000 + Int.random(in: 0...4_000_000_000))
                try? await Task.sleep(nanoseconds: jitter)
                // 掉线保险：连续两集抓不到提示登录
                if miss >= 2, got == 0, have == 0 {
                    hint = "⚠️ 连续缺集——可能登录失效，建议先手动开一集验证登录再继续"
                }
            }
            running = false
            hint = stop ? "已停止：成功 \(got) · 已有 \(have) · 缺 \(miss)"
                        : "跑完：成功 \(got) · 已有 \(have) · 缺 \(miss)（缺集可再点一次流水线重试）"
            log("流水线结束 " + hint)
        }
    }
    func stopRun() {
        stop = true
        hint = "停止中(等当前集收尾)…"
    }
    func cancelJob() {
        stop = true; job?.cancel()
    }
}

// ===================== 隐形演员 WebView（挂在页面 1px 处防懒加载装死） =====================
final class SniffAgent: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let wv: WKWebView
    private weak var vmc: SniffVM?

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        cfg.allowsInlineMediaPlayback = true
        wv = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "sniff")
        ucc.addUserScript(WKUserScript(source: SiteBrowser.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        wv.navigationDelegate = self
        wv.customUserAgent = SniffConst.desktopUA
    }
    func load(_ u: String, into vm: SniffVM) {
        vmc = vm
        guard let url = URL(string: u) else { return }
        wv.load(URLRequest(url: url))
    }
    func detach() {
        wv.navigationDelegate = nil
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "sniff")
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if let vm = vmc {
            let t = w.title ?? ""
            Task { @MainActor in
                if vm.pageTitle.isEmpty || vm.pageTitle.hasPrefix("抖音") { vm.pageTitle = t }
                vm.log("agent 页面就绪: " + String(t.prefix(28)))
            }
        }
    }
    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String,
              let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let vm = vmc else { return }
        let t = d["t"] as? String ?? "net"
        switch t {
        case "vid":
            if let v = d["v"] as? String { Task { @MainActor in vm.currentFileVid = v } }
        case "title":
            if let tt = d["v"] as? String, !tt.isEmpty {
                Task { @MainActor in
                    if vm.pageTitle.isEmpty || vm.pageTitle.hasPrefix("抖音") { vm.pageTitle = tt }
                }
            }
        case "urls":
            if let lst = d["list"] as? [String] {
                Task { @MainActor in for x in lst { vm.add(x) } }
            }
        default:
            if let u = d["u"] as? String { Task { @MainActor in vm.add(u) } }
        }
    }
}

// 舞台视图：把演员 WebView 挂进层级（1px 高，看得见动静又不占地方）
struct AgentStage: UIViewRepresentable {
    let agent: SniffAgent
    func makeUIView(context: Context) -> WKWebView {
        agent.wv.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        return agent.wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// 独立抓取：裸连+桌面UA 优先，退带 referer；两枪都要过 ftyp 魔数
func autoFetch(_ raw: String, _ prog: @escaping (Double) -> Void) async throws -> URL {
    guard let u = URL(string: raw) else { throw GError.failed("地址无效") }
    let p: @Sendable (Double, Double) -> Void = { f, _ in prog(f) }
    var last: Error?
    for refer in ["", "https://www.douyin.com/"] {
        do {
            let f = try await DouyinAPI.download(u, referer: refer, cookie: "",
                                                 uaOverride: SniffConst.desktopUA, progress: p)
            let magicOK: Bool = {
                guard let h = try? Data(contentsOf: f, options: .mappedIfSafe).prefix(12),
                      h.count >= 8 else { return false }
                return String(data: h.subdata(in: 4..<8), encoding: .ascii) == "ftyp"
            }()
            let sz = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? Int ?? 0
            guard magicOK, sz >= 1_500_000 else {
                try? FileManager.default.removeItem(at: f)
                throw GError.failed("验货被拒(\(sz / 1024)KB/魔数)")
            }
            return f
        } catch { last = error }
    }
    throw last ?? GError.failed("下载失败")
}

// ===================== 流水线页面 =====================
final class AgentBox: ObservableObject {
    let agent = SniffAgent()
}

struct SniffAutoView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = SniffAutoVM()
    @StateObject private var box = AgentBox()
    let eps: [MixEpisode]
    let base: String
    let mixID: String
    var folder: String = ""

    var body: some View {
        List {
            Section {
                AgentStage(agent: box.agent)
                    .frame(height: 10)
                HStack {
                    if vm.running {
                        Button("停止", role: .destructive) { vm.stopRun() }
                    } else {
                        Button("🤖 启动流水线（\(eps.count) 集）") {
                            let f = Naming.sanitize(folder.isEmpty ? "短剧合集" : folder)
                            vm.start(eps: eps, base: base, folder: f, mixID: mixID)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                if !vm.hint.isEmpty { Text(vm.hint).font(.footnote).foregroundStyle(.orange) }
            } header: {
                Text("逐集开页→嗅本集→验货→入库；每集间歇防风控，页面底部小窗可看现场")
            }
            Section("集单") {
                ForEach(vm.rows) { r in
                    HStack {
                        Text("第 \(r.num) 集").font(.callout)
                        Text(String(r.title.prefix(12))).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(r.state).font(.caption2).foregroundStyle(
                            r.state.hasPrefix("✓") ? Color.green : (r.state.hasPrefix("✗") ? Color.red : .secondary))
                    }
                }
                if vm.rows.isEmpty {
                    Text("点上方启动键开工")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !vm.logs.isEmpty {
                Section("调试日志") {
                    Text(vm.logs.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("整剧自动补漏")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.agent = box.agent }
        .onDisappear {
            vm.cancelJob()
            box.agent.detach()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { if !vm.running { dismiss() } }
            }
        }
    }
}
