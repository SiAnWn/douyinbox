import Foundation

// ============ 纯 Swift AES-128（表由 GF(2^8) 构造生成；含 FIPS-197 官方向量自检）============
// 设计参照 N_m3u8DL-RE(MIT) 的解密思路；state 按列主序 b[4c+r]
enum AES {
    // 官方 FIPS-197 表(与 python 独立实现+双向官方向量验证一致 2026-11-13)
    static let sbox: [UInt8] = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16
    ]
    static let invSbox: [UInt8] = [
    0x52, 0x09, 0x6A, 0xD5, 0x30, 0x36, 0xA5, 0x38, 0xBF, 0x40, 0xA3, 0x9E, 0x81, 0xF3, 0xD7, 0xFB,
    0x7C, 0xE3, 0x39, 0x82, 0x9B, 0x2F, 0xFF, 0x87, 0x34, 0x8E, 0x43, 0x44, 0xC4, 0xDE, 0xE9, 0xCB,
    0x54, 0x7B, 0x94, 0x32, 0xA6, 0xC2, 0x23, 0x3D, 0xEE, 0x4C, 0x95, 0x0B, 0x42, 0xFA, 0xC3, 0x4E,
    0x08, 0x2E, 0xA1, 0x66, 0x28, 0xD9, 0x24, 0xB2, 0x76, 0x5B, 0xA2, 0x49, 0x6D, 0x8B, 0xD1, 0x25,
    0x72, 0xF8, 0xF6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xD4, 0xA4, 0x5C, 0xCC, 0x5D, 0x65, 0xB6, 0x92,
    0x6C, 0x70, 0x48, 0x50, 0xFD, 0xED, 0xB9, 0xDA, 0x5E, 0x15, 0x46, 0x57, 0xA7, 0x8D, 0x9D, 0x84,
    0x90, 0xD8, 0xAB, 0x00, 0x8C, 0xBC, 0xD3, 0x0A, 0xF7, 0xE4, 0x58, 0x05, 0xB8, 0xB3, 0x45, 0x06,
    0xD0, 0x2C, 0x1E, 0x8F, 0xCA, 0x3F, 0x0F, 0x02, 0xC1, 0xAF, 0xBD, 0x03, 0x01, 0x13, 0x8A, 0x6B,
    0x3A, 0x91, 0x11, 0x41, 0x4F, 0x67, 0xDC, 0xEA, 0x97, 0xF2, 0xCF, 0xCE, 0xF0, 0xB4, 0xE6, 0x73,
    0x96, 0xAC, 0x74, 0x22, 0xE7, 0xAD, 0x35, 0x85, 0xE2, 0xF9, 0x37, 0xE8, 0x1C, 0x75, 0xDF, 0x6E,
    0x47, 0xF1, 0x1A, 0x71, 0x1D, 0x29, 0xC5, 0x89, 0x6F, 0xB7, 0x62, 0x0E, 0xAA, 0x18, 0xBE, 0x1B,
    0xFC, 0x56, 0x3E, 0x4B, 0xC6, 0xD2, 0x79, 0x20, 0x9A, 0xDB, 0xC0, 0xFE, 0x78, 0xCD, 0x5A, 0xF4,
    0x1F, 0xDD, 0xA8, 0x33, 0x88, 0x07, 0xC7, 0x31, 0xB1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xEC, 0x5F,
    0x60, 0x51, 0x7F, 0xA9, 0x19, 0xB5, 0x4A, 0x0D, 0x2D, 0xE5, 0x7A, 0x9F, 0x93, 0xC9, 0x9C, 0xEF,
    0xA0, 0xE0, 0x3B, 0x4D, 0xAE, 0x2A, 0xF5, 0xB0, 0xC8, 0xEB, 0xBB, 0x3C, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2B, 0x04, 0x7E, 0xBA, 0x77, 0xD6, 0x26, 0xE1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0C, 0x7D
    ]

    static func gmul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var aa = a, bb = b, acc: UInt8 = 0
        while bb != 0 {
            if bb & 1 != 0 { acc ^= aa }
            let hi = aa & 0x80
            aa <<= 1
            if hi != 0 { aa ^= 0x1B }
            bb >>= 1
        }
        return acc
    }

    static func expandKey(_ k: [UInt8]) -> [UInt8] {
        var w = Array(k[0..<16])
        var rcon: UInt8 = 0x01
        for i in 4..<44 {
            var t = Array(w[(i - 1) * 4 ..< i * 4])
            if i % 4 == 0 {
                t = [t[1], t[2], t[3], t[0]]
                t = t.map { sbox[Int($0)] }
                t[0] ^= rcon
                rcon = gmul(rcon, 2)
            }
            for j in 0..<4 { w.append(w[(i - 4) * 4 + j] ^ t[j]) }
        }
        return w
    }
    static func subBytes(_ b: inout [UInt8], inverse: Bool) {
        for i in 0..<16 { b[i] = inverse ? invSbox[Int(b[i])] : sbox[Int(b[i])] }
    }
    static func shiftRows(_ b: inout [UInt8], inverse: Bool) {
        for r in 0..<4 {
            var line = [b[r], b[r + 4], b[r + 8], b[r + 12]]          // 行 r 的 4 列(列主序)
            let n = inverse ? (4 - r) : r                             // 加密左移 r，解密右移 r
            for i in 0..<4 { b[r + i * 4] = line[(i + n) % 4] }
        }
    }
    static func mixColumns(_ s: inout [UInt8], inverse: Bool) {
        for c in 0..<4 {
            let a0 = s[c], a1 = s[4 + c], a2 = s[8 + c], a3 = s[12 + c]
            if !inverse {
                s[c]      = gmul(a0,2) ^ gmul(a1,3) ^ a2 ^ a3
                s[4 + c]  = a0 ^ gmul(a1,2) ^ gmul(a2,3) ^ a3
                s[8 + c]  = a0 ^ a1 ^ gmul(a2,2) ^ gmul(a3,3)
                s[12 + c] = gmul(a0,3) ^ a1 ^ a2 ^ gmul(a3,2)
            } else {
                s[c]      = gmul(a0,0x0E) ^ gmul(a1,0x0B) ^ gmul(a2,0x0D) ^ gmul(a3,0x09)
                s[4 + c]  = gmul(a0,0x09) ^ gmul(a1,0x0E) ^ gmul(a2,0x0B) ^ gmul(a3,0x0D)
                s[8 + c]  = gmul(a0,0x0D) ^ gmul(a1,0x09) ^ gmul(a2,0x0E) ^ gmul(a3,0x0B)
                s[12 + c] = gmul(a0,0x0B) ^ gmul(a1,0x0D) ^ gmul(a2,0x09) ^ gmul(a3,0x0E)
            }
        }
    }
    static func addRoundKey(_ b: inout [UInt8], rk: [UInt8], round: Int) {
        for i in 0..<16 { b[i] ^= rk[round * 16 + i] }
    }
    static func encryptBlock(_ b: inout [UInt8], rk: [UInt8]) {
        addRoundKey(&b, rk: rk, round: 0)
        for round in 1...10 {
            subBytes(&b, inverse: false)
            shiftRows(&b, inverse: false)
            if round < 10 { mixColumns(&b, inverse: false) }
            addRoundKey(&b, rk: rk, round: round)
        }
    }
    static func decryptBlock(_ b: inout [UInt8], rk: [UInt8]) {
        addRoundKey(&b, rk: rk, round: 10)
        var round = 9
        while round >= 0 {
            subBytes(&b, inverse: true)
            shiftRows(&b, inverse: true)
            if round > 0 { mixColumns(&b, inverse: true) }
            addRoundKey(&b, rk: rk, round: round)
            round -= 1
        }
    }
    // CBC 解密 + PKCS7 去尾
    static func cbcDecrypt(_ ct: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let rk = expandKey(key)
        var out = [UInt8](repeating: 0, count: ct.count)
        var prev = iv
        var i = 0
        while i + 16 <= ct.count {
            var blk = Array(ct[i ..< i + 16])
            decryptBlock(&blk, rk: rk)
            for j in 0..<16 { blk[j] ^= prev[j] }
            for j in 0..<16 { out[i + j] = blk[j] }
            prev = Array(ct[i ..< i + 16])
            i += 16
        }
        if let pad = out.last, pad >= 1, pad <= 16, out.count >= Int(pad) {
            let tail = Array(out.suffix(Int(pad)))
            if tail.allSatisfy({ $0 == pad }) { out.removeLast(Int(pad)) }
        }
        return out
    }

    static var ready = false
    static var readyError: String?
    static func ensureReady() throws {
        if ready {
            if let e = readyError { throw GError.failed("AES 自检失败: \(e)") }
            return
        }
        ready = true
        let key: [UInt8] = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF]
        let pt:  [UInt8] = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF]
        let want:[UInt8] = [0x69,0xC4,0xE0,0xD8,0x6A,0x7B,0x04,0x30,0xD8,0xCD,0xB7,0x80,0x70,0xB4,0xC5,0x5A]
        let rk = expandKey(key)
        var blk = pt
        encryptBlock(&blk, rk: rk)
        if blk != want { readyError = "ECB 官方向量不符"; throw GError.failed("AES 自检失败: ECB 官方向量不符") }
        var d = blk
        decryptBlock(&d, rk: rk)
        if d != pt { readyError = "解密往返不符"; throw GError.failed("AES 自检失败: 解密往返不符") }
    }
}

// ===================== HLS：m3u8 解析 + 并发下载 + 顺序解密落盘 =====================
struct HLSToken {                       // 站点请求上下文
    var referer = ""
    var cookie = ""
    var headers: [String: String] = [:]
}

enum HLS {
    struct Manifest {
        var keyMethod = "NONE"
        var keyURL: URL?
        var keyIV: [UInt8]?
        var initURL: URL?
        var segments: [URL] = []
        var segKeyURLs: [URL?] = []      // 与 segments 平行：逐分片密钥(轮换)
        var segIVs: [[UInt8]?] = []      // 与 segments 平行：逐分片 IV(nil=按序号)
        var seqStart = 0
    }

    static func fetch(_ u: URL, tok: HLSToken) async throws -> Data {
        let f = try await BatchTransfer.shared.download(u, referer: tok.referer, cookie: tok.cookie, extra: tok.headers)
        defer { try? FileManager.default.removeItem(at: f) }
        return try Data(contentsOf: f)
    }

    static func resolveBase(_ raw: String, base: URL) -> URL? {
        if raw.contains("://") { return URL(string: raw) }
        return URL(string: raw, relativeTo: base)
    }

    static func loadMedia(m3u8URL: URL, tok: HLSToken) async throws -> Manifest {
        let rawText = String(decoding: try await fetch(m3u8URL, tok: tok), as: UTF8.self)
        if !rawText.contains("#EXTM3U") {
            throw GError.failed("拿到的不是播放列表（地址可能已过期或站点拒绝直连）：回网页重新点播放后再下载")
        }
        if rawText.contains("#EXT-X-STREAM-INF") {
            // master：挑 BANDWIDTH(同值看 RESOLUTION) 最高的 media
            var bestBW = -1, bestRes = -1, bestURL = ""
            var wantLine = false
            for line in rawText.split(separator: "\n", omittingEmptySubsequences: true) {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("#EXT-X-STREAM-INF") {
                    wantLine = true
                    continue
                }
                if wantLine && !l.isEmpty && !l.hasPrefix("#") {
                    wantLine = false
                    let bw = Int(RegexHelper.firstGroup(l, pattern: "BANDWIDTH=(\\d+)") ?? "") ?? 0
                    let res = Int(RegexHelper.firstGroup(l, pattern: "RESOLUTION=(\\d+)x") ?? "") ?? 0
                    if bw > bestBW || (bw == bestBW && res > bestRes) {
                        bestBW = bw; bestRes = res; bestURL = String(l)
                    }
                }
            }
            if !bestURL.isEmpty {
                guard let mu = resolveBase(bestURL, base: m3u8URL) else { throw GError.noStream }
                return try await loadMedia(m3u8URL: mu, tok: tok)
            }
        }
        var m = Manifest()
        var seen = Set<String>()
        var curMethod = "NONE"
        var curKeyURL: URL?
        var curIV: [UInt8]?
        for line in rawText.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                m.seqStart = Int(RegexHelper.firstGroup(l, pattern: "(\\d+)") ?? "") ?? 0
            } else if l.hasPrefix("#EXT-X-MAP") {
                if let uri = RegexHelper.firstGroup(l, pattern: "URI=\"([^\"]+)\""), let u = resolveBase(uri, base: m3u8URL) {
                    m.initURL = u
                }
            } else if l.hasPrefix("#EXT-X-KEY") {
                let method = RegexHelper.firstGroup(l, pattern: "METHOD=([^,]+)") ?? "NONE"
                if method == "NONE" {
                    m.keyMethod = "NONE"; m.keyURL = nil
                    curMethod = "NONE"; curKeyURL = nil; curIV = nil
                } else {
                    m.keyMethod = method
                    curMethod = method
                    let uri = RegexHelper.firstGroup(l, pattern: "URI=\"([^\"]+)\"") ?? ""
                    if let u = resolveBase(uri, base: m3u8URL) { m.keyURL = u; curKeyURL = u }
                    curIV = nil
                    if let h = RegexHelper.firstGroup(l, pattern: "IV=0x([0-9a-fA-F]{32})") {
                        var iv = [UInt8]()
                        var pos = h.startIndex
                        for _ in 0..<16 {
                            let nx = h.index(pos, offsetBy: 2)
                            iv.append(UInt8(h[pos ..< nx], radix: 16) ?? 0)
                            pos = nx
                        }
                        m.keyIV = iv
                        curIV = iv
                    }
                }
            } else if !l.hasPrefix("#") && !l.isEmpty {
                guard let u = resolveBase(l, base: m3u8URL) else { continue }
                if !seen.contains(u.absoluteString) {          // 去重复分片（片头/广告循环）
                    seen.insert(u.absoluteString)
                    m.segments.append(u)
                    m.segKeyURLs.append(curMethod == "AES-128" ? curKeyURL : nil)
                    m.segIVs.append(curMethod == "AES-128" ? curIV : nil)
                }
            }
        }
        if m.segments.isEmpty { throw GError.failed("清单里没有分片（可能是直播页或还没开播）") }
        if m.keyMethod != "NONE" && m.keyMethod != "AES-128" {
            throw GError.failed("该加密方式(\(m.keyMethod))暂不支持：SAMPLE-AES/真DRM 类")
        }
        return m
    }

    // 拉取+解密+合并写成一个 .ts；返回实际保存的相对路径
    static func download(m3u8URLString: String, tok: HLSToken, destRel: String,
                         progress: @escaping @Sendable (Double, Double) -> Void) async throws -> String {
        try AES.ensureReady()
        guard let first = URL(string: m3u8URLString) else { throw GError.noStream }
        let m = try await loadMedia(m3u8URL: first, tok: tok)
        // 支持密钥轮换：收集去重所有分片用到的 key，一次性预取
        var keyDict: [String: [UInt8]] = [:]
        if m.keyMethod == "AES-128" {
            var need = Set<String>()
            for ku in m.segKeyURLs { if let ku = ku { need.insert(ku.absoluteString) } }
            if need.isEmpty { if let ku = m.keyURL { need.insert(ku.absoluteString) } }
            for us in need {
                guard let ku = URL(string: us) else { continue }
                let kd = try await fetch(ku, tok: tok)
                if kd.count != 16 { throw GError.failed("密钥长度异常(\(kd.count))") }
                keyDict[us] = [UInt8](kd)
            }
            if keyDict.isEmpty { throw GError.failed("缺密钥 URL") }
        }
        var initData: Data? = nil
        if let iu = m.initURL { initData = try await fetch(iu, tok: tok) }

        let segs = m.segments
        let total = segs.count
        let keyDictLocal = keyDict
        let segKeyStrs: [String?] = m.segKeyURLs.map { $0?.absoluteString }
        let segIVList: [[UInt8]?] = m.segIVs
        let seq0 = m.seqStart
        let tokLocal = tok

        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls_\(Int(Date().timeIntervalSince1970)).ts")
        FileManager.default.createFile(atPath: outFile.path, contents: Data())
        guard let fh = FileHandle(forWritingAtPath: outFile.path) else { throw GError.failed("打不开临时输出") }
        if let idat = initData { try? fh.write(contentsOf: idat) }

        var buf = [Int: [UInt8]]()
        var flushed = 0, failures = 0
        var writtenBytes = 0.0
        var lastT = Date(), speedAvg = 0.0
        var writeErr: String?
        var waveStart = 0

        while waveStart < total && failures <= 3 {
            let waveEnd = min(waveStart + 24, total)
            await withTaskGroup(of: (Int, [UInt8], String?).self) { group in
                for idx in waveStart ..< waveEnd {
                    group.addTask {
                        do {
                            let d = try await BatchTransfer.shared.download(
                                segs[idx], referer: tokLocal.referer, cookie: tokLocal.cookie, extra: tokLocal.headers)
                            defer { try? FileManager.default.removeItem(at: d) }
                            var bytes = [UInt8](try Data(contentsOf: d))
                            if let ks = segKeyStrs[idx], let kk = keyDictLocal[ks] {
                                let iv = segIVList[idx] ?? HLS.ivFromSeq(seq0 + idx)
                                bytes = AES.cbcDecrypt(bytes, key: kk, iv: iv)
                            }
                            bytes = TSRestuff.fix(bytes)          // 非标 TS 自动整形(ovod 类)
                            return (idx, bytes, nil)
                        } catch {
                            return (idx, [], error.localizedDescription)
                        }
                    }
                }
                for await (idx, bytes, errStr) in group {
                    if errStr != nil { failures += 1 } else { buf[idx] = bytes }
                    while flushed < idx + 1 && buf[flushed] != nil {
                        let b = buf[flushed]!
                        buf.removeValue(forKey: flushed)
                        if writeErr == nil {
                            do { try fh.write(contentsOf: Data(b)) } catch { writeErr = error.localizedDescription }
                        }
                        writtenBytes += Double(b.count)
                        flushed += 1
                    }
                    let nowT = Date()
                    let dt = nowT.timeIntervalSince(lastT)
                    if dt > 0.3 {
                        let inst = writtenBytes / dt
                        speedAvg = speedAvg == 0 ? inst : speedAvg * 0.7 + inst * 0.3
                        lastT = nowT
                    }
                    progress(Double(flushed) / Double(max(total, 1)), speedAvg)
                    if failures > 3 { group.cancelAll(); break }
                }
            }
            waveStart = waveEnd
            if failures > 3 { break }
        }
        try? fh.close()
        if flushed < total {
            try? FileManager.default.removeItem(at: outFile)
            throw GError.failed("分片失败过多(\(flushed)/\(total))，稍后重试")
        }
        if let e = writeErr {
            try? FileManager.default.removeItem(at: outFile)
            throw GError.failed("写盘失败: \(e)")
        }
        if !SavePaths.write(outFile, rel: destRel) {
            try? FileManager.default.removeItem(at: outFile)
            throw GError.failed("保存到库失败")
        }
        try? FileManager.default.removeItem(at: outFile)
        return destRel
    }

    static func ivFromSeq(_ seq: Int) -> [UInt8] {
        var iv = [UInt8](repeating: 0, count: 16)
        var v = seq
        for i in stride(from: 15, through: 12, by: -1) {
            iv[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        return iv
    }
}

// ===================== 站点规则 · boat 系小站（已实测）=====================
enum BoatSite {
    static func videoID(from pageURL: String) -> String? {
        RegexHelper.firstGroup(pageURL, pattern: "/videos/(\\d{3,})/?$")
            ?? RegexHelper.firstGroup(pageURL, pattern: "/videos/(\\d{3,})/")
    }
    struct StreamItem { let label: String; let m3u8: String }
    static func streams(pageURL: String) async throws -> [StreamItem] {
        guard let id = videoID(from: pageURL) else { throw GError.noURL }
        _ = id
        guard URL(string: pageURL) != nil else { throw GError.noURL }
        let trimmed = pageURL.hasSuffix("/") ? String(pageURL.dropLast()) : pageURL
        guard let api = URL(string: trimmed + "/playback") else { throw GError.noURL }
        var req = URLRequest(url: api)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.setValue(pageURL, forHTTPHeaderField: "Referer")
        req.setValue(DouyinAPI.ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { throw GError.http(h.statusCode) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let d = obj?["data"] as? [String: Any],
              let streams = d["streams"] as? [String: Any] else {
            let msg = ((obj?["msg"] as? String) ?? "接口没给流地址")
            throw GError.failed("playback 接口失败: \(msg)")
        }
        var out: [StreamItem] = []
        if let v = streams["hevc"] as? String, !v.isEmpty, v.contains("m3u8") {
            out.append(StreamItem(label: "HEVC 高画质(优先)", m3u8: v))
        }
        if let v = streams["main"] as? String, !v.isEmpty, v.contains("m3u8") {
            out.append(StreamItem(label: "AVC 高画质", m3u8: v))
        }
        if out.isEmpty { throw GError.failed("接口没返回可下载流") }
        return out
    }
}

// 抓页面 <title> 用于命名
enum PageTitle {
    static func fetch(_ pageURL: String) async -> String {
        guard let url = URL(string: pageURL) else { return "" }
        var req = URLRequest(url: url)
        req.setValue(DouyinAPI.ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return "" }
        let h = String(decoding: data, as: UTF8.self)
        if let t = RegexHelper.firstGroup(h, pattern: "<(?:title|h1)>([^<]{2,80})") {
            return Naming.sanitize(t.trimmingCharacters(in: .whitespaces))
        }
        return ""
    }
}
