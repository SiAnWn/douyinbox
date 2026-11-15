import SwiftUI
import Foundation

// MARK: - Telegram 公开频道视频收割（v1，纯 HTML，无 WebView）
// t.me/s/<channel> 是服务端直出预览页：video 直链(cdn*.telesco.pe mp4)、
// data-post 分页锚、poster 就在页面里——URLSession 拉一页解析一页，天然无风控。

struct TGItem: Identifiable, Hashable {
    let id: String        // ch/12345
    var date: String
    var caption: String
    var url: URL
    var poster: String
}

enum TGParse {
    static let cdn = #"https://cdn\d+\.telesco\.pe/file/[^"&<\s)]+"#

    static func html(_ raw: String, channel: String, before: Int?) throws -> [TGItem] {
        // 按消息块切分
        let open = "js-widget_message_wrap"
        var items: [TGItem] = []
        var cuts: [String.Index] = []
        var search = raw.startIndex
        while let r = raw.range(of: open, range: search...) {
            cuts.append(r.lowerBound)
            search = r.upperBound
        }
        guard !cuts.isEmpty else { return [] }
        cuts.append(raw.endIndex)
        let reCDN = try! NSRegularExpression(pattern: cdn)
        let rePost = try! NSRegularExpression(pattern: #"data-post="([^"]+)""#)
        let reTime = try! NSRegularExpression(pattern: #"datetime="([^"]+)""#)
        let reText = try! NSRegularExpression(pattern: #"js-message_text[^>]*>([\s\S]*?)</div>"#)
        for i in 0..<(cuts.count - 1) {
            let blk = String(raw[cuts[i]..<cuts[i + 1]])
            let br = blk.startIndex...blk.endIndex
            let mAll = reCDN.matches(in: blk, range: NSRange(br, in: blk))
            var video: URL?
            var poster = ""
            for m in mAll {
                guard let rng = Range(m.range, in: blk) else { continue }
                var u = String(blk[rng]).replacingOccurrences(of: "&amp;", with: "&")
                if u.hasSuffix("\"") { u = String(u.dropLast()) }
                if u.contains(".mp4") {
                    if video == nil, let uu = URL(string: u) { video = uu }
                } else if poster.isEmpty, u.contains(".jpg") || u.contains(".jpeg") || u.contains(".png") {
                    poster = u
                }
            }
            guard let v = video else { continue }
            let pid = rePost.firstMatch(in: blk, range: NSRange(br, in: blk)).flatMap { m -> String? in
                guard let r = Range(m.range(at: 1), in: blk) else { return nil }
                return String(blk[r])
            } ?? "?"
            let dt = reTime.firstMatch(in: blk, range: NSRange(br, in: blk)).flatMap { m -> String? in
                guard let r = Range(m.range(at: 1), in: blk) else { return nil }
                return String(blk[r]).prefix(10).description
            } ?? ""
            var cap = ""
            if let tm = reText.firstMatch(in: blk, range: NSRange(br, in: blk)),
               let r = Range(tm.range(at: 1), in: blk) {
                cap = String(blk[r])
                    .replacingOccurrences(of: "<br/>", with: " ")
                    .replacingOccurrences(of: "<br>", with: " ")
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#0147;", with: "\"")
                    .replacingOccurrences(of: "&#0148;", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            items.append(TGItem(id: pid, date: dt, caption: String(cap.prefix(120)), url: v, poster: poster))
        }
        return items
    }

    @MainActor
    static func fetch(channel: String, before: Int?) async throws -> [TGItem] {
        var u = "https://t.me/s/\(channel)"
        if let b = before { u += "?before=\(b)" }
        var req = URLRequest(url: URL(string: u)!)
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            throw TGError("频道不存在或无公开预览")
        }
        guard let html = String(data: data, encoding: .utf8) else { throw TGError("页面编码异常") }
        let items = try html(html, channel: channel, before: before)
        if items.isEmpty, html.contains("If you have an account") {
            throw TGError("这个频道没有公开预览页")
        }
        return items
    }
}

struct TGError: Error, LocalizedError {
    let m: String
    init(_ s: String) { m = s }
    var errorDescription: String? { m }
}

// MARK: - 收割台

struct TGHarvestView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var jobs = TuoleiJobs.shared
    @State private var channel = ""
    @State private var items: [TGItem] = []
    @State private var busy = false
    @State private var err = ""
    @State private var downloading = Set<String>()
    @State private var saved = Set<String>()
    @State private var recents: [String] = UserDefaults.standard.stringArray(forKey: "tgRecents") ?? []

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("频道名，如 telegram 或整条 t.me 链接", text: $channel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("收割") { run() }
                        .disabled(busy || channel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !recents.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recents, id: \.self) { c in
                                Button(c) { channel = c; run() }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                if busy { ProgressView() }
                if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
            }
            if !items.isEmpty {
                Section {
                    HStack {
                        Text("\(items.count) 条视频")
                        Spacer()
                        Button {
                            loadMore()
                        } label: { Text("再翻一页") }
                        .disabled(busy)
                        Button {
                            saveAll()
                        } label: { Text("全部下载").foregroundStyle(.orange) }
                    }
                }
                ForEach(items) { it in
                    TGRow(it: it,
                          down: downloading.contains(it.id),
                          done: saved.contains(it.id),
                          save: { save(it) })
                }
            } else if !busy && items.isEmpty {
                Section {
                    Text("输入公开频道名开始收割；无公开预览的频道会提示。\n直链即下即存：telesco 的 token 有时效，抓到就下最稳。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("TG 收割")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private struct TGRow: View {
        let it: TGItem
        let down: Bool
        let done: Bool
        let save: () -> Void
        var body: some View {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: it.poster)) { im in
                    im.resizable().scaledToFill()
                } placeholder: { Color.gray.opacity(0.15) }
                .frame(width: 56, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(it.caption.isEmpty ? "（无文字）" : it.caption)
                        .font(.subheadline).lineLimit(3)
                    Text(it.date + " · " + it.id).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    save()
                } label: {
                    if down { ProgressView().controlSize(.small) }
                    else if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Image(systemName: "tray.and.arrow.down").foregroundStyle(.orange) }
                }
                .disabled(down)
            }
        }
    }

    private func norm(_ s: String) -> String {
        var c = s.trimmingCharacters(in: .whitespaces)
        if let r = c.range(of: "t.me/s/") { c = String(c[r.upperBound...]) }
        else if let r = c.range(of: "t.me/") { c = String(c[r.upperBound...]) }
        c = c.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? c
        return c
    }

    private func run() {
        let c = norm(channel)
        guard !c.isEmpty else { return }
        busy = true; err = ""
        Task { @MainActor in
            defer { busy = false }
            do {
                let got = try await TGParse.fetch(channel: c, before: nil)
                items = got
                err = got.isEmpty ? "这页没有视频（可能全是图片/文字帖）" : ""
                var rec = recents
                rec.removeAll { $0 == c }
                rec.insert(c, at: 0)
                recents = Array(rec.prefix(8))
                UserDefaults.standard.set(recents, forKey: "tgRecents")
            } catch { err = "\(error)" }
        }
    }

    private func loadMore() {
        let c = norm(channel)
        guard let first = items.first, let slash = first.id.lastIndex(of: "/"),
              let beforeId = Int(first.id[slash...].dropFirst()) else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let got = try await TGParse.fetch(channel: c, before: beforeId)
                let known = Set(items.map(\.id))
                var merged = items
                merged.append(contentsOf: got.filter { !known.contains($0.id) })
                items = merged
            } catch { err = "\(error)" }
        }
    }

    private func save(_ it: TGItem) {
        guard !downloading.contains(it.id) else { return }
        downloading.insert(it.id)
        let c = norm(channel)
        Task { @MainActor in
            defer { downloading.remove(it.id) }
            app.keepAlive.start()
            defer { if TuoleiJobs.shared.runningCount == 0 { app.keepAlive.stop() } }
            let jid = jobs.add("TG " + c + " " + it.id, total: 1)
            do {
                let file = try await fetchToTemp(it.url)
                let sz = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
                guard sz >= 100_000 else {
                    try? FileManager.default.removeItem(at: file)
                    throw TGError("文件过小(\(sz / 1024)KB)，token 可能过期：刷新后重存")
                }
                let idClean = it.id.replacingOccurrences(of: "/", with: "_")
                let name = "TG_\(c)_\(idClean).mp4"
                if SavePaths.write(file, rel: name) {
                    saved.insert(it.id)
                    jobs.progress(jid, 1, 0)
                    jobs.finish(jid)
                    app.refresh()
                    BoxIsland.banner("百宝箱 · TG 收割", name + " 已入库")
                } else { throw TGError("写入资料库失败") }
            } catch {
                jobs.progress(jid, 0, 1)
                jobs.finish(jid)
                err = "存失败 \(it.id)：\(error)"
                BoxIsland.banner("百宝箱 · TG 收割", "失败 \(String("\(error)".prefix(60)))")
            }
        }
    }

    private func saveAll() {
        Task { @MainActor in
            for it in items where !saved.contains(it.id) && !downloading.contains(it.id) {
                save(it)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func fetchToTemp(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            throw TGError("下载 http \(h.statusCode)")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgdl_\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}
