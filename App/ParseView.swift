import SwiftUI
import UIKit
import Openhongguo

struct ParseView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var input = ""
    @State private var lastAutoClip = ""   // 最近一次已自动解析的剪贴板链接
    @State private var autoPickAfterParse = false   // 灵动岛“开始下载”：解析完直接下最优档
    @State private var islandFrac = 0.0             // 岛下载进度节流（历史遗留）
    @State private var islandDownAnnounced = false  // 岛极简：本轮是否已报过"下载中"
    @State private var status = "粘贴抖音（或B站/快手）链接 → 选清晰度或自动批量"
    @State private var busy = false
    @State private var result: ParseResult?
    @State private var mix: MixData?
    @State private var progress = 0.0
    @State private var speedText = ""
    @State private var showProgress = false
    @State private var showSettings = false
    @State private var quota = Quota.zero
    @State private var saveTarget = UserDefaults.standard.integer(forKey: "saveTarget")   // 0库 1私密 2短剧
    @State private var savedLink = ""
    @FocusState private var linkFocused: Bool

    private var engine: Engine { EngineStore.current }

    var body: some View {
        NavigationStack {
            Form {
                Section("链接") {
                    HStack {
                        TextField("抖音 / B站 / 快手 链接", text: $input)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($linkFocused)
                        if !input.isEmpty {
                            Button { input = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.borderless)
                        }
                        Button { Task { await pasteAndParse() } } label: {
                            Image(systemName: "doc.on.clipboard").foregroundStyle(.tint)
                        }.buttonStyle(.borderless)
                    }
                }
                Section {
                    Button {
                        linkFocused = false
                        Task { await parseWithFreshClip() }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "处理中…" : (input.isEmpty ? "一键粘贴并解析" : "解析 / 识别合集"))
                        }
                    }.disabled(busy)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                    if showProgress {
                        ProgressView(value: min(max(progress, 0), 1))
                        Text("\(Int(progress * 100))% · \(speedText)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("引擎 · 用量") {
                    Button { showSettings = true } label: {
                        Label("当前引擎：\(engine.label)", systemImage: "gearshape")
                            .font(.footnote)
                    }
                    if engine.isIfphp {
                        Text("今日 \(quota.day)/\(CallStats.limits.day) · 本月 \(quota.month)/\(CallStats.limits.month)")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("免费无配额，单条约 5~25 秒，仅支持抖音")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    HStack { Spacer(); Button("收起键盘") { linkFocused = false } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationTitle("视频解析")
            .overlay(alignment: .bottom) {
                Text("DouyinBox v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.55))
                    .padding(.bottom, 34)
                    .allowsHitTesting(false)
            }
            .sheet(item: $result) { res in
                QualitySheet(result: res,
                             target: Binding(get: { saveTarget },
                                             set: { saveTarget = $0; UserDefaults.standard.set($0, forKey: "saveTarget") }),
                             downloaded: { opt in isDownloaded(res, opt) },
                             onPick: { opt, idx in Task { await pick(res, opt, idx: idx) } },
                             onPickImages: { Task { await saveImages(res) } })
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $mix) { m in
                BatchSheet(mix: m).environmentObject(app)
            }
            .onChange(of: app.islandPending) { v in
                guard let l = v, !busy else { app.islandPending = nil; return }
                app.islandPending = nil
                autoPickAfterParse = true
                input = l
                status = "灵动岛下单：自动解析并下载最优档…"
                Task { await doParse(link: l) }
            }
            .onAppear { refreshQuota(); autoFillAndParse() }
            .onChange(of: scenePhase) { _ in
                if scenePhase == .active { autoFillAndParse() }
            }
            // scenePhase 在"从别的 App 切回"时经常漏报；UIKit 的激活通知每次都必发
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                // 稍等半秒：部分场景剪贴板内容落地比激活通知还晚一点点
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    autoFillAndParse()
                }
            }
        }
    }

    private func clipURL() -> String? {
        guard let clip = UIPasteboard.general.string,
              let url = DouyinAPI.extractURL(clip),
              Support.hostOK(url, engine) else { return nil }
        return url
    }

    // 剪贴板里只要有 http 链接就取出来（不论站点支不支持）
    private func clipAnyURL() -> String? {
        guard let clip = UIPasteboard.general.string else { return nil }
        return DouyinAPI.extractURL(clip)
    }

    private func autoFillAndParse() {
        guard !busy else { return }
        guard let url = clipURL() else { return }
        if url == lastAutoClip { return }   // 这条已经自动解析过，不再浪费配额
        lastAutoClip = url
        if app.selection != .parse { app.selection = .parse }   // 在别的页切回也直接跳到解析开干
        autoPickAfterParse = true           // 一键流：解析完自动下最高画质，随后自动回抖音
        input = url
        status = "已自动填入，正在解析（完成后自动下载）…"
        Task { await doParse(link: url) }
    }

    private func pasteAndParse() async {
        guard !busy else { return }
        if let url = clipURL() {
            input = url
            await doParse(link: url)
            return
        }
        if let any = clipAnyURL() {          // 有链接：能自动救的一律救
            input = any
            if engine != .svparse && Support.hostOK(any, .svparse) {
                EngineStore.current = .svparse
                status = "非抖音链接：已自动切换「多平台」引擎并解析…"
                await doParse(link: any)
                return
            }
            status = "已粘贴，但该站点暂无引擎支持（可试切「多平台」引擎）"
            return
        }
        status = "剪贴板里没有链接"
    }

    private func parseWithFreshClip() async {
        guard !busy else { return }
        if let url = clipURL() {
            input = url
            await doParse(link: url)
        } else if let any = clipAnyURL(), any != input {
            input = any
            if engine != .svparse && Support.hostOK(any, .svparse) {
                EngineStore.current = .svparse
                status = "非抖音链接：已自动切换「多平台」引擎并解析…"
                await doParse(link: any)
                return
            }
            status = "已粘贴，但该站点暂无引擎支持（可试切「多平台」引擎）"
        } else if !input.isEmpty {
            status = "剪贴板没有新链接，用框内现有链接解析"
            await doParse(link: input)
        } else {
            status = "剪贴板没有链接，输入框也是空"
        }
    }

    // 图文作品：逐张下载到 App 内（库根 图集_标题/01.jpg…），附说明.txt
    private func saveImages(_ res: ParseResult) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let title = Naming.sanitize(res.title.isEmpty ? "图集" : String(res.title.prefix(60)))
        let folder = "图集_" + title
        let total = res.images.count
        var ok = 0, fails = 0
        for (i, s) in res.images.enumerated() {
            status = String(format: "存图 %d/%d…", i + 1, total)
            guard let u = URL(string: s) else { fails += 1; continue }
            do {
                let f = try await DouyinAPI.download(u, referer: "https://www.douyin.com/",
                                                     progress: { _, _ in })
                let rawExt = u.pathExtension.lowercased()
                let ext = ImgKinds.exts.contains(rawExt) ? rawExt : "jpg"
                let rel = folder + "/" + String(format: "%02d.%@", i + 1, ext)
                let sz = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
                if sz >= 5_000 && SavePaths.write(f, rel: rel) { ok += 1 } else { fails += 1 }
                try? FileManager.default.removeItem(at: f)
            } catch { fails += 1 }
        }
        if ok > 0 {
            let meta = (res.title.isEmpty ? "" : res.title + "\n")
                + (res.author.isEmpty ? "" : "作者: " + res.author + "\n") + savedLink
            if let dat = meta.data(using: .utf8) {
                let dest = Library.root().appendingPathComponent(folder).appendingPathComponent("说明.txt")
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? dat.write(to: dest)
            }
        }
        status = ok > 0
            ? "图集已存 App：\(ok) 张" + (fails > 0 ? "（\(fails) 张失败）" : "") + "，库页图集区翻看"
            : "图集保存失败（\(fails) 张）"
        app.refresh()
    }

    @MainActor
    private func doParse(link: String) async {
        if engine.isIfphp && KeyStore.value(for: engine).isEmpty {
            status = "当前引擎需要 Key，请在 ⚙ 设置填写"
            showSettings = true
            return
        }
        if engine.isIfphp, let r = CallStats.blockReason() {
            status = "已达限制：\(r)"
            return
        }
        busy = true; savedLink = link; lastAutoClip = link
        defer { busy = false; refreshQuota() }
        defer { autoPickAfterParse = false }
        do {
            // 站点规则·boat 系小站（实测过，直连 playback API，不开浏览器不耗配额）
            if let vid = BoatSite.videoID(from: link) {
                status = "站点规则命中(boat)，查询播放流…"
                let st = try await BoatSite.streams(pageURL: link)
                let t = await PageTitle.fetch(link)
                result = ParseResult(videoID: "boat_\(vid)",
                    title: t.isEmpty ? "boat 视频 \(vid)" : t, author: "",
                    options: st.map { QualityOption(label: $0.label,
                        url: URL(string: $0.m3u8) ?? URL(string: "https://placeholder.local")!,
                        width: 0, height: 0, sizeBytes: 0, isOriginal: true, isHLS: true) })
                status = "流地址已就绪（时效很短，请尽快选档）"
                return
            }
            // 直接粘贴 .m3u8 直链 → 走通用 HLS 管线
            if link.lowercased().contains(".m3u8") {
                let rawName = URL(string: link)?.deletingPathExtension().lastPathComponent ?? "m3u8"
                let t = Naming.sanitize(rawName)
                result = ParseResult(videoID: "hls_\(String(link.prefix(90)))",
                    title: t.isEmpty ? "m3u8 视频" : t, author: "",
                    options: [QualityOption(label: "m3u8 直链（通用）",
                        url: URL(string: link) ?? URL(string: "https://placeholder.local")!,
                        width: 0, height: 0, sizeBytes: 0, isOriginal: true, isHLS: true)])
                status = "选一个清晰度下载（走 HLS 管线）"
                return
            }
            status = "识别链接类型…"
            let resolved = await MixAPI.resolve(link) ?? link
            if let mixID = MixAPI.mixID(from: resolved) {
                status = "是合集！拉剧集列表（免费）…"
                mix = try await MixAPI.fetch(mixID: mixID)
                status = "合集已就绪，开始批量"
                return
            }
            status = "解析中（\(engine == .web ? "浏览器引擎较慢…" : "API 直连…")）"
            // 拿到链接立刻回抖音：API 引擎后台可继续解析（续命音频先开），
            // 网页引擎会被挂起所以维持"下载启动后再走"的老节奏；红果要留面板也不早退
            var earlyReturn = false
            if autoPickAfterParse && app.autoReturn && engine != .web && !Hongguo.isHongguo(link) {
                app.keepAlive.start()
                earlyReturn = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    Self.launchDouyin()
                }
            }
            result = Hongguo.isHongguo(link)
                ? try await Hongguo.parseWithHeal(link)
                : try await ParseRouter.parse(link: link)
            if autoPickAfterParse, let r = result, let o = r.options.first,
               !r.videoID.hasPrefix("hg_") {
                status = "一键下载：\(o.label)"
                islandFrac = 0
                if !earlyReturn {
                    app.keepAlive.start()      // 静音续命：被抖音顶到后台也不冻结搬运
                }
                BoxIsland.update {
                    $0.phase = "parsing"; $0.link = link; $0.pct = 0
                    $0.title = String(r.title.prefix(40)); $0.author = String(r.author.prefix(16))
                    $0.quality = o.label; $0.note = "已开始下载"
                }
                if app.autoReturn && !earlyReturn {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        Self.launchDouyin()
                    }
                }
                // 一键流（非红果）固定落"视频库"，不吃面板里的位置记忆，
                // 免得手滑选过一次"短剧"后所有单视频都被塞进短剧夹
                saveTarget = 0
                await pick(r, o, idx: 0)
                app.keepAlive.stop()
                return
            }
            if autoPickAfterParse, let r = result, r.videoID.hasPrefix("hg_") {
                // 红果一键流：不自动下、不跳抖音，就地弹面板等选（岛显"等待"）
                BoxIsland.update { $0.phase = "parsing"; $0.pct = 0; $0.note = "已解析，回盒子选画质" }
            }
            status = "选一个清晰度下载"
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }

    // 进度中继：页内进度条 + 灵动岛（岛极简：只在首个字节到达时报一次"下载中"，此后闭嘴到完成）
    private func reportFrac(_ frac: Double, _ sps: Double) {
        Task { @MainActor in
            self.progress = frac
            self.speedText = Naming.fmtSpeed(sps)
            if !self.islandDownAnnounced {
                self.islandDownAnnounced = true
                BoxIsland.update { $0.phase = "down"; $0.pct = 0; $0.note = "下载中" }
            }
        }
    }

    // 一键流完成动作：跳回抖音，盒子退居后台继续传输
    static func launchDouyin() {
        guard let u = URL(string: "douyin://") else { return }
        UIApplication.shared.open(u) { ok in
            if !ok, let u2 = URL(string: "snssdk1128://") {
                UIApplication.shared.open(u2)
            }
        }
    }

    @MainActor
    private func pick(_ res: ParseResult, _ opt: QualityOption, idx: Int) async {
        let dkey = "\(res.videoID)|\(opt.label)"
        result = nil
        islandDownAnnounced = false
        BoxIsland.lastFinal = nil
        busy = true
        defer {
            busy = false; refreshQuota()
            // 岛统一收尾（end 高优通道，覆盖手动/自动/红果/直链全部路径）
            let fin = status
            BoxIsland.finish(ok: fin.hasPrefix("已保存"), note: fin)
            usleep(800_000)   // 让 end 请求在续命音频断开前落地
        }
        if opt.url.scheme == "hg" {
            showProgress = true; progress = 0; speedText = ""
            app.keepAlive.start()
            defer { app.keepAlive.stop(); showProgress = false }
            await hongguoRun(res, opt)
            return
        }
        if opt.isHLS {
            showProgress = true; progress = 0; speedText = ""
            do {
                var m3u8 = opt.url.absoluteString
                if savedLink.contains("/videos/") || m3u8.contains("placeholder.local") {
                    status = "刷新流地址（token 时效短）…"
                    let st = try await BoatSite.streams(pageURL: savedLink)
                    if idx < st.count { m3u8 = st[idx].m3u8 }
                }
                let name0 = Naming.fileName(res.author, res.title, opt)
                let baseName = name0.hasSuffix(".mp4") ? String(name0.dropLast(4)) : name0
                let (baseDir, sub) = relDirFor(res.author)
                let nameNoExt = baseName
                status = "下载 m3u8（自动选择引擎，必要时重封装）…"
                let saved = try await HLSSmart.download(
                    baseName: baseName, m3u8Str: m3u8,
                    tok: HLSToken(referer: savedLink.isEmpty ? m3u8 : savedLink, cookie: "", headers: [:]),
                    preferApple: false) { frac, sps in self.reportFrac(frac, sps) }
                let savedSize = (try? FileManager.default.attributesOfItem(atPath: SavePaths.docs.appendingPathComponent(saved).path))?[.size] as? Int ?? 0
                guard savedSize >= 30_000 else {
                    try? FileManager.default.removeItem(at: SavePaths.docs.appendingPathComponent(saved))
                    showProgress = false
                    status = "产物过小(\(savedSize / 1024)KB)：流地址可能已过期，回网页重新播放后再试"
                    return
                }
                let rel = baseDir.isEmpty ? saved : "\(baseDir)/\(sub)/\(saved)"
                if baseDir.isEmpty {
                    // saved 已是相对根路径
                } else {
                    // HLSSmart/HLS 写的是相对路径，位置前缀需在写盘时带上 → 这里直接移动到位
                    let fm = FileManager.default
                    let src = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(saved)
                    let dst = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(rel)
                    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: dst)
                    if (try? fm.moveItem(at: src, to: dst)) == nil { throw GError.failed("移动到目标位置失败") }
                }
                _ = nameNoExt
                showProgress = false
                DownloadStore.set(dkey, rel)
                app.refresh()
                if baseDir == "私密" { app.refreshPrivateSeries() }
                if baseDir == "短剧" { app.refreshDramaSeries() }
                status = "已保存：\(rel)"
            } catch {
                showProgress = false
                status = "m3u8 下载失败：\(error.localizedDescription)"
            }
            return
        }
        do {
            status = "下载 \(opt.label)…"
            showProgress = true; progress = 0; speedText = ""
            let file = try await DouyinAPI.download(opt.url) { frac, sps in self.reportFrac(frac, sps) }
            showProgress = false
            let sz = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
            guard sz >= 30_000 else {
                try? FileManager.default.removeItem(at: file)
                status = "文件过小(\(sz / 1024)KB)：直链可能已失效，重试或换清晰度"
                return
            }
            let name = Naming.fileName(res.author, res.title, opt)
            let (base, sub) = relDirFor(res.author)
            let rel = base.isEmpty ? name : "\(base)/\(sub)/\(name)"
            if SavePaths.write(file, rel: rel) {
                DownloadStore.set(dkey, rel)
                app.refresh()
                if base == "私密" { app.refreshPrivateSeries() }
                if base == "短剧" { app.refreshDramaSeries() }
                status = "已保存：\(rel)"
            } else {
                status = "保存失败：无法写入目录"
            }
        } catch {
            showProgress = false
            status = "下载失败：\(error.localizedDescription)"
        }
    }

    // 红果整剧批量：逐集 resolve → 下载 → CENC 解密 → 落库 短剧/<剧名>/第NN集.mp4
    private func hongguoRun(_ res: ParseResult, _ opt: QualityOption) async {
        guard let c = Hongguo.client else { status = "红果引擎初始化失败"; return }
        let sid = opt.url.host() ?? ""
        let def = opt.url.lastPathComponent
        guard !sid.isEmpty else { status = "红果剧集ID缺失"; return }
        do {
            status = "红果列全集…"
            let all = try await Hongguo.episodes(sid)
            let play = all.filter { $0.playable }
            var list = play.isEmpty ? all : play
            guard !list.isEmpty else { status = "红果没有可播分集"; return }
            let q = opt.url.query ?? ""
            if q.contains("one") {
                list = Array(list.prefix(1))
            } else {
                let rg = URLComponents(url: opt.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "range" })?.value ?? ""
                if !rg.isEmpty {
                    let want = epRangeSet(rg)
                    if !want.isEmpty { list = list.filter { want.contains($0.number) } }
                }
            }
            if list.isEmpty {
                status = "自选的集数这部剧里没有或不可播（该剧有效编号 1–\(all.count)）"
                return
            }
            let n = list.count
            let seriesName = Naming.sanitize(res.title)
            var okN = 0, failN = 0
            for (i, ep) in list.enumerated() {
                if Task.isCancelled { break }
                let num = ep.number > 0 ? ep.number : i + 1
                let rel = "短剧/\(seriesName)/" + String(format: "第%02d集.mp4", num)
                if SavePaths.exists(rel: rel) {
                    okN += 1
                    progress = Double(i + 1) / Double(n)
                    continue
                }
                status = String(format: "红果 %d/%d 集 · %@", i + 1, n, def)
                var savedOK = false
                var tried = 0
                var lastWhy = ""
                while !savedOK && tried < 3 {
                    tried += 1
                    if tried > 1 {
                        try? await c.resetDevice()
                        status = String(format: "红果第 %d 集密钥被掐，换设备重试 %d/3…", i + 1, tried)
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    let prbOpt: PlaybackResult?
                    var resolveErr = ""
                    do { prbOpt = try await Hongguo.attempt(c) { try await c.resolvePlayback(ep.id) } }
                    catch let e { prbOpt = nil; resolveErr = e.localizedDescription }
                    guard resolveErr.isEmpty, let prb = prbOpt,
                          let st = Hongguo.chooseStream(prb.playback, def: def),
                          let su = Hongguo.streamURL(st) else { lastWhy = "resolve: " + (resolveErr.isEmpty ? "no stream" : resolveErr); continue }
                    let baseFrac = Double(i) / Double(n)
                    let tmp: URL
                    do {
                        tmp = try await DouyinAPI.download(su) { f, sps in
                            self.reportFrac(baseFrac + f / Double(n), sps)
                        }
                    } catch let e { lastWhy = "download: " + e.localizedDescription; continue }
                    var encSize = 0
                    if prb.playback.protected {
                        if let ck = prb.contentKey?.key, !ck.isEmpty,
                           let data = try? Data(contentsOf: tmp),
                           let clear = CencMP4.decrypt(data, keyHex: ck) {
                            let dest = SavePaths.docs.appendingPathComponent(rel)
                            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                                     withIntermediateDirectories: true)
                            try? FileManager.default.removeItem(at: dest)
                            savedOK = (try? clear.write(to: dest)) != nil
                        } else { lastWhy = "decrypt-nil/keys" }
                        if !savedOK, tried == 3,
                           let data = try? Data(contentsOf: tmp) {
                            encSize = data.count
                            Hongguo.saveBlackBox(ep: ep.id, sid: sid, def: def, stage: lastWhy,
                                                 prot: prb.playback.protected,
                                                 key: prb.contentKey?.key ?? "",
                                                 kver: prb.contentKey?.version ?? "",
                                                 ckErr: prb.contentKeyError?.localizedDescription ?? "-",
                                                 bytes: data)
                        }
                    } else {
                        savedOK = SavePaths.write(tmp, rel: rel)
                        if !savedOK { lastWhy = "save: 明文写入失败（存储满?）" }
                    }
                    try? FileManager.default.removeItem(at: tmp)
                }
                if savedOK { okN += 1 }
                else {
                    showProgress = false
                    failN += 1
                    app.refresh()
                    app.refreshDramaSeries()
                    status = "红果失败于第 \(i + 1) 集 [\(lastWhy)]，黑匣子已存 HongguoDebug；已下 \(okN)/\(n)"
                    break
                }
                progress = Double(i + 1) / Double(n)
                DownloadStore.set("hg|\(sid)|\(num)|\(def)", rel)
                if i + 1 < n { try? await Task.sleep(nanoseconds: 700_000_000) }   // 温和限速防风控
            }
            showProgress = false
            if okN > 0 {
                try? FileManager.default.removeItem(
                    at: SavePaths.docs.appendingPathComponent("HongguoDebug", isDirectory: true))   // 成功即清黑匣子
                app.refresh()
                app.refreshDramaSeries()
                status = failN > 0
                    ? "已保存：短剧/\(seriesName)（\(okN)/\(n) 集，缺 \(failN) 集）"
                    : "已保存：短剧/\(seriesName)（共 \(n) 集）"
            } else if !status.hasPrefix("红果失败于") {
                status = "红果下载失败：没有一集成功（可能接口风控，稍后再试）"
            }
        } catch {
            showProgress = false
            status = "红果失败：\(error.localizedDescription)"
        }
    }

    private func relDirFor(_ author: String) -> (String, String) {
        let sub = Naming.sanitize(author.isEmpty ? "未命名" : author)
        switch saveTarget {
        case 1: return ("私密", sub)
        case 2: return ("短剧", sub)
        default: return ("", "")
        }
    }

    private func isDownloaded(_ res: ParseResult, _ opt: QualityOption) -> Bool {
        guard let rel = DownloadStore.map()["\(res.videoID)|\(opt.label)"] else { return false }
        return SavePaths.exists(rel: rel)
    }

    private func refreshQuota() { quota = CallStats.current() }
}

// 集数范围解析："1-5,8,11-13" → Set；坏片段整体返回空
func epRangeSet(_ s: String) -> Set<Int> {
    var out = Set<Int>()
    for part in s.split(separator: ",") {
        let t = part.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if let dash = t.firstIndex(of: "-") {
            let a = Int(t[t.startIndex..<dash]), b = Int(t[t.index(after: dash)...])
            guard let a = a, let b = b, b >= a, b - a < 200 else { return [] }
            for k in a...b { out.insert(k) }
        } else {
            guard let n = Int(t), n > 0 else { return [] }
            out.insert(n)
        }
    }
    return out
}

// MARK: - 清晰度选择（带存入位置）
struct QualitySheet: View {
    let result: ParseResult
    @Binding var target: Int
    let downloaded: (QualityOption) -> Bool
    let onPick: (QualityOption, Int) -> Void
    let onPickImages: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmOpt: QualityOption?
    @State private var confirmIdx = 0
    @State private var hgScope = 0            // 红果：0全集 1仅第1集 2自定义
    @State private var hgRange = ""           // 如 1-5,8,11-13

    private var isHg: Bool { result.videoID.hasPrefix("hg_") }

    // "1-5,8,11-13" → 排序去重集合（借用文件级 epRangeSet）
    private var hgPicked: [Int] { isHg && hgScope == 2 ? Array(epRangeSet(hgRange)).sorted() : [] }

    private var hgHintText: String {
        if !hgPicked.isEmpty { return "将下载 \(hgPicked.count) 集 · 最大 \(hgPicked.last!)" }
        return hgRange.trimmingCharacters(in: .whitespaces).isEmpty
            ? "输入集数或区间，逗号分隔；空=按全集"
            : "格式不对，将按全集下载"
    }

    private func scoped(_ opt: QualityOption) -> QualityOption {
        guard isHg, hgScope != 0 else { return opt }
        if hgScope == 1 {
            let u = URL(string: opt.url.absoluteString + "?one") ?? opt.url
            return QualityOption(label: opt.label + " · 仅第1集", url: u,
                                 width: opt.width, height: opt.height,
                                 sizeBytes: opt.sizeBytes / 40, isOriginal: opt.isOriginal)
        }
        let picked = hgPicked
        guard !picked.isEmpty else { return opt }   // 自定义格式错：按全集兜底
        let rs = picked.map(String.init).joined(separator: ",")
        let u = URL(string: opt.url.absoluteString + "?range=" + rs.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!) ?? opt.url
        return QualityOption(label: opt.label + " · 自选\(picked.count)集", url: u,
                             width: opt.width, height: opt.height,
                             sizeBytes: opt.sizeBytes / 1000 * max(1, picked.count), isOriginal: opt.isOriginal)
    }

    private var author: String { Naming.sanitize(result.author.isEmpty ? "未命名" : result.author) }

    var body: some View {
        NavigationStack {
            List {
                if !result.images.isEmpty {
                    Section {
                        Button {
                            onPickImages()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "photo.on.rectangle.angled").font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("图集 · \(result.images.count) 张").font(.body)
                                    Text("存入 App 库页图集区（不写系统相册）")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle").font(.title3)
                            }
                        }.foregroundStyle(.primary)
                    } header: {
                        Text("\(result.author.isEmpty ? "" : result.author + " · ")\(result.title)")
                            .font(.caption).lineLimit(2)
                    }
                    if result.options.isEmpty {
                        Section { Text("图文作品没有视频流").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !result.options.isEmpty {
                    Section("存入位置") {
                        Picker("存入位置", selection: $target) {
                            Text("视频库").tag(0)
                            Text("私密/\(author)").tag(1)
                            Text("短剧/\(author)").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                    if isHg {
                        Section("下载范围") {
                            Picker("范围", selection: $hgScope) {
                                Text("全集").tag(0)
                                Text("仅第1集").tag(1)
                                Text("自定义").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            if hgScope == 2 {
                                TextField("如 1-5,8,11-13", text: $hgRange)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .keyboardType(.numbersAndPunctuation)
                                Text(hgHintText)
                                    .font(.caption)
                                    .foregroundStyle(hgPicked.isEmpty ? Color.secondary : Color.blue)
                            }
                        }
                    }
                    Section {
                        ForEach(Array(result.options.enumerated()), id: \.offset) { idx, opt in
                            Button {
                                if downloaded(opt) { confirmIdx = idx; confirmOpt = opt } else { onPick(scoped(opt), idx) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(opt.label + (opt.isOriginal ? "  ⭐" : "")).font(.body)
                                        Text("\(opt.width)×\(opt.height) · \(Naming.fmtSize(opt.sizeBytes))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if downloaded(opt) { Text("已下载").font(.caption).foregroundStyle(.green) }
                                }
                            }.foregroundStyle(.primary)
                        }
                    } header: {
                        Text("\(result.author.isEmpty ? "" : result.author + " · ")\(result.title)")
                            .font(.caption).lineLimit(2)
                    }
                }
            }
            .alert("已经下载过",
                   isPresented: Binding(get: { confirmOpt != nil }, set: { if !$0 { confirmOpt = nil } }),
                   presenting: confirmOpt) { opt in
                Button("取消", role: .cancel) {}
                Button("重新下载") { onPick(opt, confirmIdx) }
            } message: { _ in
                Text("这个清晰度之前已下载过（按当前存入位置判断），要重新下载吗？")
            }
            .navigationTitle("选择清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
