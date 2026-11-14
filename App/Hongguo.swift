import Foundation
import CommonCrypto
import Openhongguo

// MARK: - 红果短剧引擎
// 分享链接 → 匿名 SDK 取全集与密钥 → 下载 cenc-aes-ctr 加密 mp4 → 本地解密清洗成普通 HEVC 文件。
// 解密算法已在电脑端对 ffmpeg 逐样本验证（12665/12665 样本零误差）。

enum Hongguo {
    static func isHongguo(_ link: String) -> Bool {
        link.contains("novelquickapp.com") || link.contains("hongguoduanju")
    }

    static let client: OpenhongguoClient? = try? OpenhongguoClient.create()

    // 短链跳转拿 series_id
    static func seriesID(from link: String) async -> String? {
        if let sid = queryValue(link, "video_series_id") { return sid }
        guard let u = URL(string: link) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 12)
        req.setValue(DouyinAPI.ua, forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForResource = 15
        let r = try? await URLSession(configuration: cfg).data(for: req)
        guard let final = r?.1.url?.absoluteString else { return nil }
        return queryValue(final, "video_series_id")
    }

    private static func queryValue(_ s: String, _ k: String) -> String? {
        guard var c = URLComponents(string: s) else { return nil }
        if c.query == nil, let q = s.range(of: "?") {
            c.query = String(s[q.upperBound...])
        }
        return c.queryItems?.first(where: { $0.name == k })?.value
    }

    // 全集聚标（自动翻页）
    static func episodes(_ sid: String) async throws -> [Episode] {
        guard let c = client else { throw GError.failed("红果引擎初始化失败") }
        var all: [Episode] = []
        var cursor = ""
        for _ in 0..<40 {
            let opts = cursor.isEmpty ? EpisodeOptions() : EpisodeOptions(cursor: cursor)
            let page = try await c.listEpisodes(sid, options: opts)
            all += page.items
            if !page.hasMore || page.cursor.isEmpty { break }
            cursor = page.cursor
        }
        return all
    }

    // 把 SDK 英文报错翻译成人话+操作指引
    static func friendly(_ e: Error) -> String {
        let m = e.localizedDescription
        if m.contains("anonymous response was empty") {
            return "红果风控：当前网络出口被回了空结果。请在 Clash 换个节点（大陆/港优）重试；反复不行就在设置里重置红果设备"
        }
        if m.contains("rate limited") { return "红果限流：歇一两分钟再试" }
        if m.contains("signature") { return "红果签名被拒：重置红果设备后重试" }
        if m.contains("authentication") { return "这部剧需要登录红果账号才能匿名取流" }
        if m.contains("transport") { return "红果网络不通：检查代理后重试" }
        return "红果失败：" + m
    }

    // 遇到"匿名空结果"风控：自动换一台匿名设备重试一次，仍败则中文报错
    static func attempt<T>(_ c: OpenhongguoClient, _ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch {
            let e1 = error
            if e1.localizedDescription.contains("anonymous") {
                try? await c.resetDevice()
                do { return try await op() }
                catch { throw GError.failed(friendly(e1)) }
            }
            throw GError.failed(friendly(e1))
        }
    }

    // 红果每集密钥并非全局固定：episode07 实测与 01/27 不同。
    // 匿名设备档案被风控标记会导致拿到"错密钥组"（画面可解、声音花屏）。
    // 对策：解析阶段失败即换设备重试；仍失败则要求重置档案。
    static func parseWithHeal(_ link: String) async throws -> ParseResult {
        guard let c = client else { throw GError.failed("红果引擎初始化失败") }
        do {
            let r = try await parse(link)
            return r
        } catch let e where e is GError {
            // 网络/风控类失败：重置匿名设备后再试一次
            try? await c.resetDevice()
            return try await parse(link)
        }
    }

    // 失败黑匣子：加密原件 + 密钥/参数 sidecar，存 HongguoDebug/ 供离线解剖
    static func saveBlackBox(ep: String, sid: String, def: String, stage: String,
                             prot: Bool, key: String, kver: String, ckErr: String, bytes: Data) {
        let dir = SavePaths.docs.appendingPathComponent("HongguoDebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "dbg_\(ep)"
        try? bytes.write(to: dir.appendingPathComponent(base + ".enc.mp4"))
        let meta = "sid=\(sid)\nep=\(ep)\ndef=\(def)\nstage=\(stage)\nprotected=\(prot)\nkey=\(key)\nkver=\(kver)\nckErr=\(ckErr)\nbytes=\(bytes.count)\nts=\(Date())\n"
        try? meta.write(to: dir.appendingPathComponent(base + ".txt"), atomically: false, encoding: .utf8)
    }

    // 解析成清晰度列表（hg:// 占位链接，pick 时特判走整剧批量）
    static func parse(_ link: String) async throws -> ParseResult {
        guard let sid = await seriesID(from: link) else {
            throw GError.failed("红果链接里没找到剧集ID（可能版本过新）")
        }
        guard let c = client else { throw GError.failed("红果引擎初始化失败") }
        let s = try? await c.getSeries(sid)
        let eps = try await attempt(c) { try await episodes(sid) }
        guard let first = eps.first else { throw GError.failed("红果这部剧没有分集") }
        let pr = try await attempt(c) { try await c.resolvePlayback(first.id) }
        if pr.playback.protected, (pr.contentKey?.key.isEmpty ?? true) {
            throw GError.failed("拿不到红果内容密钥（风控掐了密钥）：去 设置→红果短剧 重置设备，或换节点再试")
        }
        let ladder = pr.playback.streams
            .filter { !$0.url.isEmpty && !$0.hls && !$0.dash }
            .sorted { a, b in (a.height * a.bitrate) > (b.height * b.bitrate) }
        guard !ladder.isEmpty else { throw GError.noStream }
        var opts: [QualityOption] = []
        for st in ladder {
            let perEp = st.size
            let total = perEp * max(1, eps.count)
            let szTxt = total > 0 ? "约\(Naming.fmtSize(total))" : (perEp > 0 ? "约\(Naming.fmtSize(perEp))/集" : "")
            opts.append(QualityOption(
                label: "红果 \(st.definition) · 全\(eps.count)集" + (szTxt.isEmpty ? "" : " · \(szTxt)"),
                url: URL(string: "hg://\(sid)/\(st.definition)")!,
                width: st.width, height: st.height, sizeBytes: total, isOriginal: false))
        }
        let title = (s?.title.isEmpty == false ? s!.title : (first.title.isEmpty ? "红果短剧" : first.title))
        return ParseResult(videoID: "hg_\(sid)", title: title, author: "红果", options: opts)
    }

    // 挑一集的可播流：优先 definition 一致，退而求其次最高档
    static func chooseStream(_ pb: Playback, def: String) -> Openhongguo.Stream? {
        let usable = pb.streams.filter { !$0.url.isEmpty && !$0.hls && !$0.dash }
        if let m = usable.first(where: { $0.definition.lowercased() == def.lowercased() }) { return m }
        return usable.max { a, b in (a.height * a.bitrate) < (b.height * b.bitrate) }
    }

    // 选流兜底：主地址空时用备份
    static func streamURL(_ st: Openhongguo.Stream) -> URL? {
        if !st.url.isEmpty, let x = URL(string: st.url) { return x }
        if !st.backupUrl.isEmpty, let x = URL(string: st.backupUrl) { return x }
        return nil
    }
}

// MARK: - CENC (cenc-aes-ctr) 整样本解密 + 清洗成可播 mp4
// 红果样本结构：faststart 渐进式；sinf/tenc + saio/saiz/senc 每样本 8 字节 IV；
// 计数器 = IV(8B)‖低 8 字节从 0 递增；整样本加密（无 subsample 图案）。
enum CencMP4 {
    struct BoxRef { let start: Int; let size: Int; let type: String }

    static func u32(_ d: Data, _ i: Int) -> Int {
        guard i + 4 <= d.count else { return 0 }
        return Int(d[d.startIndex + i]) << 24 | Int(d[d.startIndex + i + 1]) << 16
             | Int(d[d.startIndex + i + 2]) << 8 | Int(d[d.startIndex + i + 3])
    }

    static func fourcc(_ d: Data, _ i: Int) -> String {
        guard i + 4 <= d.count else { return "" }
        let b = [d[d.startIndex + i], d[d.startIndex + i + 1], d[d.startIndex + i + 2], d[d.startIndex + i + 3]]
        return String(bytes: b, encoding: .ascii) ?? ""
    }

    static func children(_ d: Data, _ start: Int, _ end: Int) -> [BoxRef] {
        var out: [BoxRef] = []
        var i = start
        while i + 8 <= end {
            var sz = u32(d, i)
            let tp = fourcc(d, i + 4)
            var hdr = 8
            if sz == 1 {
                guard i + 16 <= end else { break }
                sz = 0
                for k in 8..<16 { sz = sz * 256 + Int(d[d.startIndex + i + k]) }
                hdr = 16
            } else if sz == 0 {
                sz = end - i
            }
            if sz < hdr || i + sz > end || sz <= 0 { break }
            out.append(BoxRef(start: i, size: sz, type: tp))
            i += sz
        }
        return out
    }

    static func top(_ d: Data, _ name: String) -> BoxRef? {
        children(d, 0, d.count).first { $0.type == name }
    }

    // 沿 moov→trak→mdia→minf→stbl 定位 stbl 子盒
    struct StblRefs {
        let trakBox: BoxRef
        let stsd: BoxRef; let stsz: BoxRef; let stco: BoxRef; let stsc: BoxRef
        let senc: BoxRef?
        let entry: BoxRef       // stsd 第一样本描述
        let sinf: BoxRef?
        let chain: [BoxRef]     // entry/stsd/stbl/minf/mdia/trak 祖先链（自内向外）
    }

    static func traks(_ d: Data, _ moov: BoxRef) -> [StblRefs] {
        var res: [StblRefs] = []
        for trak in children(d, moov.start + 8, moov.start + moov.size) where trak.type == "trak" {
            guard let mdia = children(d, trak.start + 8, trak.start + trak.size).first(where: { $0.type == "mdia" }),
                  let minf = children(d, mdia.start + 8, mdia.start + mdia.size).first(where: { $0.type == "minf" }),
                  let stbl = children(d, minf.start + 8, minf.start + minf.size).first(where: { $0.type == "stbl" })
            else { continue }
            let kids = children(d, stbl.start + 8, stbl.start + stbl.size)
            guard let stsd = kids.first(where: { $0.type == "stsd" }),
                  let stsz = kids.first(where: { $0.type == "stsz" }),
                  let stco = kids.first(where: { $0.type == "stco" }),
                  let stsc = kids.first(where: { $0.type == "stsc" })
            else { continue }
            guard let entry = children(d, stsd.start + 16, stsd.start + stsd.size).first else { continue }
            // 样本描述子盒起点（实测校准）：visual 盒起 entry+86，audio 盒起 entry+36
            let csBase = entry.start + (entry.type == "encv" ? 86 : 36)
            var sinf: BoxRef?
            if entry.type == "encv" || entry.type == "enca" {
                sinf = children(d, csBase, entry.start + entry.size).first { $0.type == "sinf" }
            }
            let chain = [entry, stsd, stbl, minf, mdia, trak]
            res.append(StblRefs(trakBox: trak, stsd: stsd, stsz: stsz, stco: stco, stsc: stsc,
                                senc: kids.first(where: { $0.type == "senc" }), entry: entry, sinf: sinf, chain: chain))
        }
        return res
    }

    struct SampleTable {
        var offsets: [(Int, Int)]      // (文件偏移, 样本大小)
        var ivs: [Data]
    }

    static func sampleTable(_ d: Data, _ t: StblRefs) -> SampleTable? {
        let ns = u32(d, t.stsz.start + 8 + 8)          // verflags+sample_size 后是 count
        guard ns > 0 else { return nil }
        var sizes: [Int] = []
        sizes.reserveCapacity(ns)
        let szBase = t.stsz.start + 8 + 12
        for k in 0..<ns { sizes.append(u32(d, szBase + k * 4)) }
        let nc = u32(d, t.stco.start + 8 + 4)
        guard nc > 0 else { return nil }
        var ch: [Int] = []
        let chBase = t.stco.start + 8 + 8
        for k in 0..<nc { ch.append(u32(d, chBase + k * 4)) }
        let nse = u32(d, t.stsc.start + 8 + 4)
        var rules: [(Int, Int)] = []
        let rBase = t.stsc.start + 8 + 8
        for k in 0..<nse {
            let first = u32(d, rBase + k * 12)
            let spc = u32(d, rBase + k * 12 + 4)
            rules.append((first, spc))
        }
        rules.sort { $0.0 < $1.0 }
        var offs: [(Int, Int)] = []
        var si = 0
        for ci in 1...nc {
            var spc = 1
            for (f, p) in rules where ci >= f { spc = p }
            var acc = ch[ci - 1]
            for _ in 0..<spc {
                if si >= ns { break }
                offs.append((acc, sizes[si]))
                acc += sizes[si]; si += 1
            }
        }
        var ivs: [Data] = []
        if let senc = t.senc {
            let base = senc.start + 8 + 8
            guard senc.size >= 8 + 8 + ns * 8 else { return nil }
            for k in 0..<ns {
                ivs.append(d.subdata(in: d.startIndex + base + k * 8 ..< d.startIndex + base + k * 8 + 8))
            }
        } else { return nil }
        return SampleTable(offsets: offs, ivs: ivs)
    }

    static func hexToData(_ h: String) -> Data? {
        var s = h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count == 32 || s.count == 64 else { return nil }
        var out = Data()
        while !s.isEmpty {
            let two = s.prefix(2); s = String(s.dropFirst(2))
            guard let b = UInt8(two, radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }

    // AES-CTR 钝实现：ECB 批量加密计数器阵列 → XOR 进样本（CommonCrypto CTR 流模式在真机上
    // 各种边角，ECB one-shot 最笨但零陷阱）；计数器 = iv16 全 128 位大端逐块 +1
    static func ctrXOR(_ out: inout Data, _ off: Int, _ len: Int, _ iv16: Data, _ key: Data) -> Bool {
        guard off >= 0, off + len <= out.count, len > 0, key.count == 16, iv16.count == 16 else { return false }
        let nblk = (len + 15) / 16
        var counters = [UInt8](repeating: 0, count: nblk * 16)
        var ctr = [UInt8](iv16)
        for b in 0..<nblk {
            for k in 0..<16 { counters[b * 16 + k] = ctr[k] }
            // 128-bit BE +1
            var i = 15
            while i >= 0 {
                ctr[i] = ctr[i] &+ 1
                if ctr[i] != 0 { break }
                i -= 1
            }
        }
        var ks = [UInt8](repeating: 0, count: nblk * 16)
        var ksLen = 0
        let st = counters.withUnsafeBytes { cp in
            ks.withUnsafeMutableBytes { kp in
                key.withUnsafeBytes { kk in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            kk.baseAddress!, 16, cp.baseAddress!,
                            nblk * 16, kp.baseAddress!, &ksLen)
                }
            }
        }
        guard st == CCCryptorStatus(kCCSuccess), ksLen == nblk * 16, ksLen >= len else { return false }
        return out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: off)
            for j in 0..<len { p[j] ^= ks[j] }
            return true
        }
    }

    // 主入口：解密并清洗（encv→hvc1、enca→mp4a、去 sinf、stco 重定位）。失败回 nil。
    static func decrypt(_ data: Data, keyHex: String) -> Data? {
        guard let key = hexToData(keyHex) else { return nil }
        guard let moov = top(data, "moov") else { return nil }
        var out = data
        var removals: [(start: Int, len: Int)] = []
        var stcoPatches: [(boxStart: Int, entries: Int)] = []   // (stco盒起点, 条目数)
        var totalRemoved = 0

        for t in traks(data, moov) {
            guard let entryType = (t.entry.type == "encv" || t.entry.type == "enca") ? t.entry.type : nil else { continue }
            guard let tab = sampleTable(data, t) else { continue }
            guard tab.offsets.count == tab.ivs.count else { continue }
            // 1) 逐样本原地解密
            var ok = true
            for m in 0..<tab.offsets.count {
                let (off, len) = tab.offsets[m]
                var iv16 = tab.ivs[m]
                iv16.append(Data([0, 0, 0, 0, 0, 0, 0, 0]))
                if !ctrXOR(&out, off, len, iv16, key) { ok = false; break }
            }
            guard ok else { return nil }
            // 1b) 明文质检：抽前几个视频样本验 NAL 长度字段 + NAL 头字节（0x40~0x7E=H.265 类型域）
            if entryType == "encv" {
                var anyGood = false
                for m in 0..<min(3, tab.offsets.count) {
                    let (off, len) = tab.offsets[m]
                    guard len > 8 else { continue }
                    let nl = u32(out, off)
                    let b4 = out[data.startIndex + off + 4]
                    if nl > 0 && nl + 4 <= len && b4 >= 0x40 && b4 < 0x80 { anyGood = true; break }
                }
                guard anyGood else { return nil }
            }
            // 2) 描述盒改名 + 记录 sinf 摘除 + 祖先尺寸收缩
            let rename: [UInt8] = entryType == "encv" ? Array("hvc1".utf8) : Array("mp4a".utf8)
            out[data.startIndex + t.entry.start + 4] = rename[0]
            out[data.startIndex + t.entry.start + 5] = rename[1]
            out[data.startIndex + t.entry.start + 6] = rename[2]
            out[data.startIndex + t.entry.start + 7] = rename[3]
            stcoPatches.append((t.stco.start, u32(data, t.stco.start + 8 + 4)))
            // 摘 sinf + stbl 里全部加密描述盒（senc/saiz/saio/sbgp/sgpd）——
            // AVPlayer 见到残留会当加密流处理导致无声无画，ffmpeg 才会容忍
            var victims: [(BoxRef, [BoxRef])] = []
            if let sinf = t.sinf { victims.append((sinf, t.chain)) }
            let cryptoKinds: Set<String> = ["senc", "saiz", "saio", "sbgp", "sgpd"]
            let stblBox = t.chain[2]
            for k in children(data, stblBox.start + 8, stblBox.start + stblBox.size)
                where cryptoKinds.contains(k.type) {
                victims.append((k, Array(t.chain[2...])))
            }
            for (vb, chain) in victims {
                let sz = vb.size
                totalRemoved += sz
                removals.append((vb.start, sz))
                for anc in chain {   // 逐级收缩（sinf: entry/stsd/stbl/minf/mdia/trak；其余: stbl 往下）
                    let cur = u32(out, anc.start)
                    let ns = cur - sz
                    out[data.startIndex + anc.start] = UInt8((ns >> 24) & 0xFF)
                    out[data.startIndex + anc.start + 1] = UInt8((ns >> 16) & 0xFF)
                    out[data.startIndex + anc.start + 2] = UInt8((ns >> 8) & 0xFF)
                    out[data.startIndex + anc.start + 3] = UInt8(ns & 0xFF)
                }
            }
        }

        // 3) moov 整体尺寸收缩（AVPlayer 严格校验盒边界，漏这个会整段拒播）
        if totalRemoved > 0 {
            let cur = u32(out, moov.start)
            let nv = cur - totalRemoved
            out[data.startIndex + moov.start] = UInt8((nv >> 24) & 0xFF)
            out[data.startIndex + moov.start + 1] = UInt8((nv >> 16) & 0xFF)
            out[data.startIndex + moov.start + 2] = UInt8((nv >> 8) & 0xFF)
            out[data.startIndex + moov.start + 3] = UInt8(nv & 0xFF)
        }

        // 4) stco 条目值：mdat 整体左移 totalRemoved（趁删除前按原位置写值）
        for (boxStart, n) in stcoPatches {
            let nb = boxStart + 8 + 8
            for k in 0..<n {
                let oldVal = u32(out, nb + k * 4)
                let nv = oldVal - totalRemoved
                out[data.startIndex + nb + k * 4] = UInt8((nv >> 24) & 0xFF)
                out[data.startIndex + nb + k * 4 + 1] = UInt8((nv >> 16) & 0xFF)
                out[data.startIndex + nb + k * 4 + 2] = UInt8((nv >> 8) & 0xFF)
                out[data.startIndex + nb + k * 4 + 3] = UInt8(nv & 0xFF)
            }
        }

        // 4) 摘除 sinf 盒（降序删，偏移保持有效）
        for r in removals.sorted(by: { $0.start > $1.start }) {
            out.removeSubrange(data.startIndex + r.start ..< data.startIndex + r.start + r.len)
        }
        return out
    }
}
