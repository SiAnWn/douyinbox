import SwiftUI
import UIKit

struct ParseView: View {
    @EnvironmentObject var app: AppState
    @State private var input = ""
    @State private var status = "粘贴抖音链接 → 选清晰度 → 下载到本 app"
    @State private var busy = false
    @State private var result: ParseResult?
    @State private var progress = 0.0
    @State private var speedText = ""
    @State private var showProgress = false
    @State private var showSettings = false
    @State private var quota = Quota.zero
    @FocusState private var linkFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("链接") {
                    HStack {
                        TextField("抖音链接 / 分享口令", text: $input)
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
                        Task {
                            if input.isEmpty { await pasteAndParse() }
                            else { await doParse(link: input) }
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "处理中…" : (input.isEmpty ? "一键粘贴并选清晰度" : "解析并选清晰度"))
                        }
                    }.disabled(busy)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                    if showProgress {
                        ProgressView(value: min(max(progress, 0), 1))
                        Text("\(Int(progress * 100))% · \(speedText)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("接口用量") {
                    Text("今日 \(quota.day)/\(CallStats.limits.day)　本月 \(quota.month)/\(CallStats.limits.month)")
                        .font(.footnote).foregroundStyle(.secondary)
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
            .navigationTitle("抖音解析")
            .sheet(item: $result) { res in
                QualitySheet(result: res,
                             downloaded: { opt in isDownloaded(res, opt) },
                             onPick: { opt in Task { await pick(res, opt) } })
            }
            .onAppear { refreshQuota(); autoFillAndParse() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func autoFillAndParse() {
        guard input.isEmpty, !busy else { return }
        guard let url = Self.clipDouyinURL() else { return }
        input = url
        status = "已自动填入，正在解析…"
        Task { await doParse(link: url) }
    }

    // 📋 按钮 / 空输入时的一键动作：读取剪贴板 → 填入 → 直接拉清晰度
    private func pasteAndParse() async {
        guard !busy else { return }
        guard let url = Self.clipDouyinURL() else {
            status = "剪贴板里没有抖音链接"
            return
        }
        input = url
        await doParse(link: url)
    }

    private static func clipDouyinURL() -> String? {
        guard let clip = UIPasteboard.general.string,
              let url = DouyinAPI.extractURL(clip),
              url.contains("douyin.com") else { return nil }
        return url
    }

    @MainActor
    private func doParse(link: String) async {
        if KeyStore.value.isEmpty {
            status = "请先在右上角 ⚙ 设置里填写接口 Key"
            showSettings = true
            return
        }
        if let r = CallStats.blockReason() {
            status = "已达限制：\(r)"
            return
        }
        busy = true; defer { busy = false; refreshQuota() }
        do {
            status = "解析中…"
            result = try await DouyinAPI.parse(link: link)
            status = "选一个清晰度下载"
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func pick(_ res: ParseResult, _ opt: QualityOption) async {
        let dkey = "\(res.videoID)|\(opt.label)"
        result = nil
        busy = true; defer { busy = false }
        do {
            status = "下载 \(opt.label)…"
            showProgress = true; progress = 0; speedText = ""
            let file = try await DouyinAPI.download(opt.url) { frac, sps in
                Task { @MainActor in self.progress = frac; self.speedText = Naming.fmtSpeed(sps) }
            }
            showProgress = false
            let name = Naming.fileName(res.author, res.title, opt)
            if SavePaths.write(file, name: name) {
                DownloadStore.set(dkey, name)
                app.refresh()
                status = "已下载：\(name)"
            } else {
                status = "保存失败：无法写入目录"
            }
        } catch {
            showProgress = false
            status = "下载失败：\(error.localizedDescription)"
        }
    }

    private func isDownloaded(_ res: ParseResult, _ opt: QualityOption) -> Bool {
        guard let fn = DownloadStore.map()["\(res.videoID)|\(opt.label)"] else { return false }
        return SavePaths.exists(fn)
    }

    private func refreshQuota() { quota = CallStats.current() }
}

struct QualitySheet: View {
    let result: ParseResult
    let downloaded: (QualityOption) -> Bool
    let onPick: (QualityOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmOpt: QualityOption?

    var body: some View {
        NavigationStack {
            List {
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
                Text("这个清晰度之前已下载过，要重新下载吗？")
            }
            .navigationTitle("选择清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

enum DownloadStore {
    private static let key = "downloadedMap"
    static func map() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
    static func set(_ k: String, _ name: String) {
        var m = map(); m[k] = name; UserDefaults.standard.set(m, forKey: key)
    }
}
