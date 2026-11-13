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
                             onPick: { opt in Task { await pick(res, opt) } })
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

    private func autoFillAndParse() {
        guard input.isEmpty, !busy else { return }
        guard let url = clipURL() else { return }
        input = url
        status = "已自动填入，正在解析…"
        Task { await doParse(link: url) }
    }

    private func pasteAndParse() async {
        guard !busy else { return }
        guard let url = clipURL() else { status = "剪贴板里没有支持的链接"; return }
        input = url
        await doParse(link: url)
    }

    private func parseWithFreshClip() async {
        guard !busy else { return }
        if let url = clipURL() {
            input = url
            await doParse(link: url)
        } else if !input.isEmpty {
            status = "剪贴板没有新链接，用框内现有链接解析"
            await doParse(link: input)
        } else {
            status = "剪贴板没有支持的链接，输入框也是空"
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
        busy = true; defer { busy = false; refreshQuota() }
        do {
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

    // 0 视频库 / 1 私密/作者 / 2 短剧/作者
    private func relDirFor(_ author: String) -> (String, String) {
        let sub = Naming.sanitize(author.isEmpty ? "未命名" : author)
        switch saveTarget {
        case 1: return ("私密", sub)
        case 2: return ("短剧", sub)
        default: return ("", "")
        }
    }

    @MainActor
    private func pick(_ res: ParseResult, _ opt: QualityOption) async {
        let dkey = "\(res.videoID)|\(opt.label)"
        result = nil
        busy = true; defer { busy = false; refreshQuota() }
        do {
            status = "下载 \(opt.label)…"
            showProgress = true; progress = 0; speedText = ""
            let file = try await DouyinAPI.download(opt.url) { frac, sps in
                Task { @MainActor in self.progress = frac; self.speedText = Naming.fmtSpeed(sps) }
            }
            showProgress = false
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
    let onPick: (QualityOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmOpt: QualityOption?

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
                    ForEach(Array(result.options.enumerated()), id: \.offset) { _, opt in
                        Button {
                            if downloaded(opt) { confirmOpt = opt } else { onPick(opt) }
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
                Button("重新下载") { onPick(opt) }
            } message: { _ in
                Text("这个清晰度之前已下载过（按当前存入位置判断），要重新下载吗？")
            }
            .navigationTitle("选择清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
