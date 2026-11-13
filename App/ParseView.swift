import SwiftUI
import UIKit

struct ParseView: View {
    @EnvironmentObject var app: AppState
    @State private var input = ""
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
            .sheet(item: $result) { res in
                QualitySheet(result: res,
                             target: Binding(get: { saveTarget },
                                             set: { saveTarget = $0; UserDefaults.standard.set($0, forKey: "saveTarget") }),
                             downloaded: { opt in isDownloaded(res, opt) },
                             onPick: { opt, idx in Task { await pick(res, opt, idx: idx) } })
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $mix) { m in
                BatchSheet(mix: m).environmentObject(app)
            }
            .onAppear { refreshQuota(); autoFillAndParse() }
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
        guard input.isEmpty, !busy else { return }
        guard let url = clipURL() else { return }
        input = url
        status = "已自动填入，正在解析…"
        Task { await doParse(link: url) }
    }

    private func pasteAndParse() async {
        guard !busy else { return }
        if let url = clipURL() {
            input = url
            await doParse(link: url)
            return
        }
        if let any = clipAnyURL() {          // 有链接但站点不支持：照样粘进输入框
            input = any
            status = "已粘贴，但当前引擎[\(engine.label)]不认这个站点——可切引擎再解析"
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
            status = "已粘贴，但当前引擎[\(engine.label)]不认这个站点——可切引擎再解析"
        } else if !input.isEmpty {
            status = "剪贴板没有新链接，用框内现有链接解析"
            await doParse(link: input)
        } else {
            status = "剪贴板没有链接，输入框也是空"
        }
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
        busy = true; savedLink = link; defer { busy = false; refreshQuota() }
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
            result = try await ParseRouter.parse(link: link)
            status = "选一个清晰度下载"
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func pick(_ res: ParseResult, _ opt: QualityOption, idx: Int) async {
        let dkey = "\(res.videoID)|\(opt.label)"
        result = nil
        busy = true; defer { busy = false; refreshQuota() }
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
                    preferApple: false) { frac, sps in
                        Task { @MainActor in self.progress = frac; self.speedText = Naming.fmtSpeed(sps) }
                    }
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
            let file = try await DouyinAPI.download(opt.url) { frac, sps in
                Task { @MainActor in self.progress = frac; self.speedText = Naming.fmtSpeed(sps) }
            }
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

// MARK: - 清晰度选择（带存入位置）
struct QualitySheet: View {
    let result: ParseResult
    @Binding var target: Int
    let downloaded: (QualityOption) -> Bool
    let onPick: (QualityOption, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmOpt: QualityOption?
    @State private var confirmIdx = 0

    private var author: String { Naming.sanitize(result.author.isEmpty ? "未命名" : result.author) }

    var body: some View {
        NavigationStack {
            List {
                Section("存入位置") {
                    Picker("存入位置", selection: $target) {
                        Text("视频库").tag(0)
                        Text("私密/\(author)").tag(1)
                        Text("短剧/\(author)").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    ForEach(Array(result.options.enumerated()), id: \.offset) { idx, opt in
                        Button {
                            if downloaded(opt) { confirmIdx = idx; confirmOpt = opt } else { onPick(opt, idx) }
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
