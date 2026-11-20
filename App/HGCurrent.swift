import Foundation
import CryptoKit

// ============================================================
// 红果"现役播放器"新方言 (v1.10.97)
// 抄作业对象: iDuanJu STV/Providers/Hongguo/HGCurrentPlayer.swift + HGPlayerSign.swift
//              (Apache-2.0, gateway playersign 的移植; 咱再移植其 Swift→Swift, 私用不分发)
// 移植纪律: PC 同构镜像 pure_cur.py 已与 iDuanJu 官方 102 条向量全绿对表 (factor 48/48,
//           compute 全 header 32/32, transform 22/22), 再照 Swift 原件逐行落地.
// 方言亮点: ①播放器设备免注册口 —— 本地 mint 15 位随机 did (首位 5-9), iid = did+4096,
//            被网关记仇回空就丢号重造 (旧 V5 死守注册口 6h 缓存号 = 11-20 中午悬案根因);
//         ②签名 = selector 搜题: sm3(query)+bodyMD5+le32(t) → getIV → selector%3==0
//            才开工 (6 变体 SHA256 型 factor), 命中即得 ts/_rticket;
//         ③gorgon/helios/medusa 全新变体 (profile 3428B 定长表驱动).
// 通道选择: PC 实弹 (11-20 午) player batch 口
//           POST https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1
//           body=mixed_video_id_map → data[vid].video_model(串) → video_list 5 档 1080P
//           + encrypt_info.spade_a 内容密钥 (盒子 spadeKey 现成管线直接吃).
//           pure 单集口 (/video_model/v1/) PC 仍回空, 不接; 老 V5+lift 留兜底.
// ============================================================

enum HGCurrent {
    // MARK: - profile (gateway current_profile.go 定长表, 3428B)
    static let profileB64 = "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"
    static let profile: [UInt8] = Array(Data(base64Encoded: profileB64) ?? Data())
    static let material = Array(profile[0..<32])
    static let header = Array(profile[32..<48])
    static let boxes = (0..<4).map { Array(profile[(48 + $0 * 256)..<(48 + ($0 + 1) * 256)]) }
    static let initial = (0..<4).map { Array(profile[(1072 + $0 * 4)..<(1076 + $0 * 4)]) }
    static let checksum = (0..<256).map { rdLE64(profile, 1088 + $0 * 8) }
    static let factorIVt = (0..<8).map { le(profile, 3136 + $0 * 4) }
    static let factorTab = (0..<64).map { le(profile, 3168 + $0 * 4) }
    static let padding4 = Array(profile[3424..<3428])

    // MARK: - 字节小件 (本文件自带, 不连坐别处)
    static func le(_ b: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[at + $1]) << UInt32(8 * $1) }
    }
    static func be(_ b: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(b[at + $1]) }
    }
    static func le32b(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)]
    }
    static func be32b(_ v: UInt32) -> [UInt8] { Array(le32b(v).reversed()) }
    static func rdLE32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func rdLE64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(rdLE32(b, o)) | UInt64(rdLE32(b, o + 4)) << 32
    }
    static func wrLE64(_ v: UInt64) -> [UInt8] {
        le32b(UInt32(truncatingIfNeeded: v)) + le32b(UInt32(truncatingIfNeeded: v >> 32))
    }
    static func ror32(_ x: UInt32, _ n: Int) -> UInt32 {
        let n = n & 31; return n == 0 ? x : (x >> UInt32(n)) | (x << UInt32(32 - n))
    }
    static func ror64(_ x: UInt64, _ n: Int) -> UInt64 {
        let n = n & 63; return n == 0 ? x : (x >> UInt64(n)) | (x << UInt64(64 - n))
    }
    static func b64(_ b: [UInt8]) -> String { Data(b).base64EncodedString() }
    static func md5(_ d: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: Data(d))) }
    static func hexStr(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    static func getIV(_ iv: UInt32, _ data: [UInt8]) -> UInt32 {
        var v = iv
        for (i, x) in data.enumerated() {
            if i & 1 == 0 {
                v = (v >> 4) ^ v ^ (v << 6) ^ UInt32(x)
            } else {
                v = ~((v >> 7) ^ v ^ (UInt32(x) | (v << 12)))
            }
        }
        return v
    }
    // sm3 = 网关同款变体, 盒子已有 HGSM3 (v1.9.34 已与参考逐行对拍), 直接复用
    static func sm3(_ d: [UInt8]) -> [UInt8] { Array(HGBase.sm3Data(Data(d))) }

    // pct 编码 (与 JS encodeURIComponent 同规则, 保留 -_.!~*'())
    static func enc(_ s: String) -> String {
        let un = Set("-_.!~*'()".utf8)
        var o = ""
        for c in s.utf8 {
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || un.contains(c) {
                o.append(Character(UnicodeScalar(c)))
            } else {
                o += String(format: "%%%02X", c)
            }
        }
        return o
    }
    static func encodeQuery(_ pairs: [(String, String)]) -> String {
        pairs.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&")
    }

    // protobuf 小件 (与 HGV5 同款算法, 本文件自带版避免连坐)
    static func varint(_ v0: UInt64) -> [UInt8] {
        var v = v0; var o = [UInt8]()
        while v > 127 { o.append(UInt8(v & 127) | 128); v >>= 7 }
        o.append(UInt8(v)); return o
    }
    static func pKey(_ tag: UInt32, _ w: UInt8) -> [UInt8] { varint(UInt64(tag) << 3 | UInt64(w)) }
    static func pBytes(_ tag: UInt32, _ b: [UInt8]) -> [UInt8] {
        b.isEmpty ? [] : pKey(tag, 2) + varint(UInt64(b.count)) + b
    }
    static func pStr(_ tag: UInt32, _ s: String) -> [UInt8] { pBytes(tag, Array(s.utf8)) }
    static func pSInt(_ tag: UInt32, _ v0: Int64) -> [UInt8] {
        let v = v0
        let zz = UInt64(bitPattern: (v << 1) ^ (v >> 63))
        return pKey(tag, 0) + varint(zz)
    }

    // MARK: - factor (selector 六变体 SHA256 型轮)
    static func factor(_ input: [UInt8], _ seconds: UInt32, _ selector: Int) -> [UInt8]? {
        guard input.count == 52, [0, 3, 6, 9, 12, 15].contains(selector) else { return nil }
        let cfg = [(15, 100), (13, 96), (62, 94), (79, 97), (66, 96), (127, 99)][selector / 3]
        let rotation = seconds &+ UInt32(truncatingIfNeeded: cfg.0) &- 15 &+ 0xee47_628f
        let ini = factorIVt.map { ror32($0, Int(rotation & 31)) }
        let table = factorTab.map { ror32($0, Int((rotation &+ 1) & 31)) }
        var block = input + [UInt8](repeating: 0, count: 12)
        let shift = Int((rotation &+ 2) & 7)
        for i in 0..<4 {
            let x = UInt32(padding4[i])
            block[52 + i] = UInt8(truncatingIfNeeded: x >> UInt32(shift) | x << UInt32((8 - shift) & 7))
        }
        block[62] = 1; block[63] = 0xa0
        var w = [UInt32](repeating: 0, count: 128)
        for i in 0..<16 { w[i] = be(block, i * 4) }
        for i in 16..<128 {
            let x = w[i - 15], y = w[i - 2]
            w[i] = w[i - 16] &+ (ror32(x, 7) ^ ror32(x, 18) ^ (x >> 3)) &+ w[i - 7] &+ (ror32(y, 17) ^ ror32(y, 19) ^ (y >> 10))
        }
        var v = ini
        func sig(_ x: UInt32) -> UInt32 { ror32(x, 6) ^ ror32(x, 11) ^ ror32(x, 25) }
        func upper(_ x: UInt32) -> UInt32 { ror32(x, 2) ^ ror32(x, 13) ^ ror32(x, 22) }
        for round in 0..<cfg.1 {
            let a = v[0], b = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7]
            let kw = table[(cfg.0 + round) & 63] &+ w[(cfg.0 + round) & 127]
            var nv = v
            switch selector {
            case 0:
                let t = kw &+ (c ^ (e & (f ^ c))) &+ sig(e) &+ g
                nv = [t &+ h, a, b, c, d, e, f, ((a & b) | ((b | a) & d)) &+ upper(a) &+ t]
            case 3:
                let t = kw &+ (h ^ (a & (c ^ h))) &+ sig(a) &+ b
                nv = [h, a, ((f & d) | ((d | f) & g)) &+ upper(f) &+ t, c, d, t &+ e, f, g]
            case 6:
                let t = kw &+ (a ^ (d & (b ^ a))) &+ sig(d) &+ c
                nv = [h, a, b, ((h & g) | ((g | h) & f)) &+ upper(h) &+ t, d, t &+ e, f, g]
            case 9:
                let t = kw &+ (b ^ (c & (f ^ b))) &+ sig(c) &+ d
                nv = [h, t &+ a, b, c, ((g & h) | ((h | g) & e)) &+ upper(g) &+ t, e, f, g]
            case 12:
                let t = kw &+ (e ^ (b & (a ^ e))) &+ sig(b) &+ g
                nv = [t &+ h, a, b, c, d, e, f, ((d & f) | ((f | d) & c)) &+ upper(d) &+ t]
            default:
                let t = kw &+ (a ^ (b & (d ^ a))) &+ sig(b) &+ f
                nv = [h, a, b, c, d, t &+ e, ((g & c) | ((c | g) & h)) &+ upper(g) &+ t, g]
            }
            v = nv
        }
        let digest = (0..<8).flatMap { be32b(ini[$0] &+ v[$0]) }
        var out = [UInt8](repeating: 0, count: 20)
        for i in 0..<16 { out[i] = digest[i] ^ digest[i + 16] }
        var state: UInt32 = 0x2022_0420
        for i in 0..<8 {
            let x = UInt32(out[i])
            if i % 2 == 1 {
                state = ~((state ^ ((state << 11) | x) ^ (state >> 5)))
            } else {
                state = state ^ (state << 7) ^ x ^ (state >> 3)
            }
        }
        out.replaceSubrange(16..<20, with: le32b((state & ~0x24) ^ 0x0100_0000))
        return out
    }

    // MARK: - compute: gorgon / helios / medusa 全家
    static func compute(query: String, digest: [UInt8], pb: [UInt8], mat: [UInt8], license: String, aid: String,
                        seconds t: UInt64, nonce: UInt16, flags: UInt16,
                        heliosRandom: UInt32, random1: UInt32, random2: UInt32,
                        local: UInt64, previous: UInt32) -> (headers: [String: String], state: UInt32)? {
        guard mat.count == 32, digest.count == 16, (2...32768).contains(pb.count) else { return nil }
        var crc: UInt64 = 0
        for ch in license.utf8 {
            crc = checksum[Int(UInt8(truncatingIfNeeded: crc) ^ ch)] ^ (crc >> 8)
        }
        let state = UInt32(truncatingIfNeeded: ror64(crc ^ t ^ local, 60)) ^ previous
        var h = [
            "x-khronos": String(t),
            "x-argus": b64(le32b(UInt32(truncatingIfNeeded: t))),
            "x-ladon": b64(be32b(state)),
            "x-gorgon": gorgon(query, digest, t, nonce, flags),
            "x-helios": helios(t, license, aid, heliosRandom),
        ]
        guard let md = medusa(pb, mat, t, random1, random2) else { return nil }
        h["x-medusa"] = md
        return (h, state)
    }

    static func gorgon(_ query: String, _ digest: [UInt8], _ t: UInt64, _ nonce: UInt16, _ flags: UInt16) -> String {
        let key: [Int] = [0x4a, Int(flags & 255), 0x16, Int(nonce >> 8), 0x47, 0x6c, Int(flags >> 8), Int(nonce & 255)]
        var table = Array(0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + table[i] + key[i % 8]) & 255
            table[i] = table[j]        // 赋值不交换 (current 方言特色, 照抄)
        }
        let seed = Array(md5(Array(query.utf8)).prefix(4)) + Array(digest.prefix(4))
            + [UInt8](repeating: 0, count: 4) + [0, 9, 9, 4] + be32b(UInt32(truncatingIfNeeded: t))
        var out = [UInt8](repeating: 0, count: 20)
        j = 0
        for n in 0..<20 {
            let i = n + 1
            j = (j &+ table[i & 255]) & 255
            let y = table[j & 255]
            table[i & 255] = y
            out[n] = seed[n] ^ UInt8(truncatingIfNeeded: table[(y + y) & 255])
        }
        for i in 0..<20 {
            let x = out[i]
            let swapped = (x >> 4) | (x << 4)
            let v = out[(i + 1) % 20] ^ swapped
            var reverse: UInt8 = 0
            for b in 0..<8 { reverse |= ((v >> UInt8(b)) & 1) << UInt8(7 - b) }
            out[i] = ~(reverse ^ 20)
        }
        return hexStr([0x84, 4, UInt8(truncatingIfNeeded: nonce), UInt8(nonce >> 8),
                       UInt8(truncatingIfNeeded: flags), UInt8(flags >> 8)] + out)
    }

    static func helios(_ t: UInt64, _ license: String, _ aid: String, _ random: UInt32) -> String {
        let key = Array(hexStr(md5(le32b(random) + Array(aid.utf8))).utf8)
        var keys = [UInt64](repeating: 0, count: 35)
        keys[0] = rdLE64(key, 0)
        var a = keys[0]
        var b = rdLE64(key, 8)
        var queue = [rdLE64(key, 16), rdLE64(key, 24)]
        for i in 0..<34 {
            var x = (ror64(b, 8) &+ a) ^ UInt64(i)
            queue.append(x)
            x ^= ror64(a, 61)
            keys[i + 1] = x
            a = x
            b = queue.removeFirst()
        }
        let raw = Array("\(t)-\(license)-\(aid)".utf8)
        let n = 16 - raw.count % 16
        let plain = raw + [UInt8](repeating: UInt8(n), count: n)
        var out = le32b(random)
        for at in stride(from: 0, to: plain.count, by: 16) {
            var l = rdLE64(plain, at), r = rdLE64(plain, at + 8)
            for i in 0..<34 {
                r = keys[i] ^ (l &+ ror64(r, 8))
                l = r ^ ror64(l, 61)
            }
            out += wrLE64(l) + wrLE64(r)
        }
        return b64(out)
    }

    static func ks(_ pb: [UInt8], _ mat: [UInt8], _ t: [UInt8]) -> [UInt8] {
        let box = sm3(mat + t + mat)
        let n = pb.count
        var b = [UInt8](repeating: 0, count: n)
        for i in pb.indices {
            let a = UInt32(box[(4 * i) % 32])
            let c = UInt32(box[(4 * i + 1) % 32])
            let x = UInt32(pb[i])
            let w = ~((((x >> 4) | (x << 4)) &+ a) ^ c)
            let rot = ((w << 3) & 0xffff_fff8) | ((w >> 5) & 7)
            b[n - 1 - i] = UInt8(truncatingIfNeeded: ~(a ^ (rot &+ c)))
        }
        let last = b[n - 1], prev = b[n - 2]
        b[0] = b[0] &+ ~(last ^ prev)
        b[1] = (b[0] ^ last ^ 254) &+ b[1]
        for j in 2..<(n - 1) {
            let v = UInt32(b[j - 1])
            let rot = ((v >> 5) & 7) | (v << 3)
            b[j] = b[j] &+ UInt8(truncatingIfNeeded: ~(UInt32(b[j - 2]) ^ rot ^ UInt32(j)))
        }
        b[n - 1] ^= b[n - 2]
        let sum = b.dropFirst().reduce(UInt8(0), &+)
        b[0] = (b[0] ^ b[1]) &+ sum
        let reg = ~(((UInt32(t[2]) << 11) | UInt32(t[3])) ^ UInt32(t[2]) ^ (UInt32(t[2]) >> 5))
        let mask = be32b(reg)
        let stream = [UInt8](repeating: 0, count: 8) + b
        return stream.indices.map { mask[$0 % 4] ^ stream[stream.count - 1 - $0] }
    }

    static let con = [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]]
    static let order = [[0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
                        [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
                        [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
                        [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7]]

    static func transform(_ plain: [UInt8], _ key: [UInt8], _ iv: [UInt8], _ branch: Int) -> [UInt8]? {
        guard key.count == 16, iv.count == 16, (0...3).contains(branch) else { return nil }
        var expanded = [UInt8](repeating: 0, count: 48)
        let box = boxes[branch]
        let ini = le(initial[branch], 0)
        for i in 0..<16 { expanded[i] = key[i] ^ initial[branch][i % 4] }
        var rounds = 8
        for i in 4..<12 {
            let at = 4 * (i - 1)
            var a = expanded[at], b = expanded[at + 1], c = expanded[at + 2], d = expanded[at + 3]
            if i & 3 == 0 {
                let old = a
                a = UInt8(truncatingIfNeeded: (ini >> UInt32(rounds & 24)) ^ UInt32(box[Int(b)]))
                b = box[Int(c)]; c = box[Int(d)]; d = box[Int(old)]
            }
            rounds += 2
            for (j, v) in [a, b, c, d].enumerated() { expanded[at + 4 + j] = v ^ expanded[at - 12 + j] }
        }
        let pad = 16 - plain.count % 16
        let source = plain + [UInt8](repeating: UInt8(pad), count: pad)
        var previous = iv
        var out = [UInt8]()
        let co = con[branch]
        let ord = order[branch]
        var at = 0
        while at < source.count {
            var state = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 {
                let keyIndex = 4 * (i / 4) + co[i % 4]
                state[i] = source[at + i] ^ previous[i] ^ expanded[keyIndex]
            }
            for round in 1...2 {
                var old = state
                for i in 0..<16 { state[i] = box[Int(old[co[i / 4] * 4 + i % 4])] }
                old = state
                for i in 0..<16 { state[i] = old[ord[i]] }
                if round == 1 {
                    old = state
                    for i in 0..<16 { state[i] = old[4 * (i / 4) + co[i % 4]] }
                    for j in 0..<4 {
                        let total = state[j] ^ state[4 + j] ^ state[8 + j] ^ state[12 + j]
                        let first = state[j]
                        for i in 0..<4 {
                            let next = i < 3 ? state[(i + 1) * 4 + j] : first
                            let x = state[i * 4 + j] ^ next
                            let xt = (x << 1) ^ (x & 128 != 0 ? 0x1b : 0)
                            state[i * 4 + j] ^= total ^ xt
                        }
                    }
                }
                for i in 0..<16 { state[i] ^= expanded[16 * round + 4 * (i / 4) + co[i % 4]] }
            }
            previous = (0..<16).map { state[$0] ^ expanded[16 + $0] }
            out += previous
            at += 16
        }
        return out
    }

    static func mid(_ pb: [UInt8]) -> UInt16? {
        var at = 0
        var first = [Int](repeating: -1, count: 2)
        func read() -> UInt64? {
            var v: UInt64 = 0
            for i in 0..<10 {
                guard at < pb.count else { return nil }
                let b = pb[at]; at += 1
                guard i < 9 || b <= 1 else { return nil }
                v |= UInt64(b & 127) << (7 * i)
                if b & 128 == 0 { return v }
            }
            return nil
        }
        while at < pb.count {
            guard let tag = read() else { return nil }
            guard tag >> 3 != 0 else { return nil }
            switch tag & 7 {
            case 0: _ = read()
            case 1: at += 8
            case 5: at += 4
            case 2:
                guard let n64 = read(), n64 <= UInt64(pb.count - at) else { return nil }
                let n = Int(n64), field = Int(tag >> 3)
                if (13...14).contains(field), n > 0 { first[field - 13] = Int(pb[at]) }
                at += n
            default: return nil
            }
            guard at <= pb.count else { return nil }
        }
        guard first[0] >= 0, first[1] >= 0 else { return nil }
        return UInt16(first[0] & 63) | UInt16(first[1] & 63) << 6
    }

    static func medusa(_ pb: [UInt8], _ mat: [UInt8], _ t: UInt64, _ r1: UInt32, _ r2: UInt32) -> String? {
        guard let m = mid(pb) else { return nil }
        let t4 = le32b(r1)
        var prefix: UInt32 = 0
        for (i, x) in mat.enumerated() {
            let x = UInt32(x)
            prefix = i % 2 == 0 ? prefix ^ (prefix << 7) ^ x ^ (prefix >> 3)
                                : prefix ^ ~((prefix << 11) ^ x ^ (prefix >> 5))
        }
        var pre = [UInt8(truncatingIfNeeded: prefix)] + le32b(r2)
        pre += [1, UInt8(truncatingIfNeeded: m), UInt8(m >> 8), 0x18]
        pre += ks(pb, mat, t4) + Array(t4[2..<4])
        guard pre.count >= 248 else { return nil }
        let lane = [6, 5, 3, 4, 2, 7, 1, 0]
        let bits = [1, 7, 3, 6, 2, 0, 4, 5]
        var plain = [UInt8](repeating: 0, count: 31)
        for i in 0..<248 {
            plain[i / 8] |= ((pre[i] >> lane[i % 8]) & 1) << bits[i % 8]
        }
        guard let channel = transform(plain, Array(md5(Array(mat[0..<16]))), Array(md5(Array(mat[16..<32]))), Int(t & 3)) else { return nil }
        var body = pre
        for i in 0..<248 {
            body[i] = (body[i] & ~(1 << lane[i % 8])) | (((channel[i / 8] >> bits[i % 8]) & 1) << lane[i % 8])
        }
        var hdr = le32b(5) + header
        let mask = le32b(UInt32(truncatingIfNeeded: t))
        for i in hdr.indices { hdr[i] ^= mask[i % 4] }
        return b64(hdr + Array(t4.prefix(2)) + [0, 1, channel[31]] + body)
    }

    static func protobuf(_ t: UInt32, _ did: String, _ version: String, _ nonce: UInt32,
                         _ fac: [UInt8], _ hash6: [UInt8]) -> [UInt8] {
        func n(_ tag: UInt32, _ v: Int64) -> [UInt8] { pSInt(tag, v) }
        func s(_ tag: UInt32, _ v: String) -> [UInt8] { pStr(tag, v) }
        var pb = pBytes(1, header)
        pb += n(2, 5) + n(3, Int64(nonce)) + s(4, "8662") + s(5, did) + s(6, "646637794")
        pb += s(7, version) + s(8, "v04.10.03-ml-android") + n(9, 135_529_984 / 2)
        pb += pBytes(10, [UInt8](repeating: 0, count: 8)) + n(12, Int64(t))
        pb += pBytes(13, fac) + pBytes(14, hash6)
        pb += pBytes(15, n(1, 1) + n(2, 1) + n(3, 1)) + n(17, Int64(t)) + s(20, "none") + n(21, 377)
        let env = n(1, 100) + n(5, 7) + s(6, "v04.10.03.04-bugfix") + n(7, 10001) + s(14, version)
        pb += pBytes(23, env)
        pb += s(24, #"{"cmr":16777216,"cmr2":16777216,"vpn":0,"kd":0,"dyn":"","do":0,"tk":false}"#)
        return pb
    }

    // MARK: - sign (selector 搜题)
    static func sign(pairs: [(String, String)], nowMillis: Int64, deviceID: String,
                     versionName: String, body: [UInt8], entropy: [UInt8]? = nil) -> (query: String, headers: [String: String])? {
        let ent = entropy ?? (0..<24).map { _ in UInt8.random(in: 0...255) }
        guard nowMillis >= 1000, nowMillis <= Int64(Int32.max) * 1000 - 128,
              !deviceID.isEmpty, deviceID.count <= 64,
              !versionName.isEmpty, versionName.count <= 32, ent.count == 24 else { return nil }
        let base = pairs.filter { $0.0 != "ts" && $0.0 != "_rticket" }
        let digest = md5(body)
        for offset in Int64(0)..<128 {
            let ticket = nowMillis &+ offset
            let t = UInt32(ticket / 1000)
            let query = encodeQuery(base + [("ts", String(t)), ("_rticket", String(ticket))])
            guard query.utf8.count <= 32768 else { return nil }
            let hash = sm3(Array(query.utf8))
            let input = hash + digest + le32b(t)
            let selector = Int(getIV(0x2023_0928, input) & 15)
            if selector % 3 != 0 { continue }
            guard let f = factor(input, t, selector) else { continue }
            let pb = protobuf(t, deviceID, versionName, le(ent, 0), f, Array(hash.prefix(6)))
            guard var h = compute(query: query, digest: digest, pb: pb, mat: material,
                                  license: "646637794", aid: "8662",
                                  seconds: UInt64(t), nonce: UInt16(ent[0]) | UInt16(ent[1]) << 8, flags: 0x101,
                                  heliosRandom: le(ent, 4), random1: le(ent, 8), random2: le(ent, 12),
                                  local: 0x1000_0000, previous: le(ent, 16))?.headers else { continue }
            h["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
            h["Content-Type"] = "application/json; charset=utf-8"
            h["x-xs-from-web"] = "0"
            h["sdk-version"] = "2"
            h["x-ss-req-ticket"] = String(ticket)
            h["x-ss-stub"] = hexStr(digest)   // current 方言: 小写 md5 (batch 老方言是大写, 别混)
            return (query, h)
        }
        return nil
    }

    // MARK: - 设备本地 mint (免注册口! 被记仇就丢号重造)
    struct CurDev { let did: String; let iid: String }
    static func mint() -> CurDev {
        var digits = [UInt8](repeating: 0, count: 15)
        for i in 0..<15 { digits[i] = UInt8.random(in: 0...255) }
        var s = String(5 + Int(digits[0] % 5))
        for i in 1..<15 { s.append(String(digits[i] % 10)) }
        return CurDev(did: s, iid: String((Int64(s) ?? 0) + 4096))
    }
    static func stableUUID(_ seed: String) -> String {
        var b = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x40
        b[8] = (b[8] & 0x3f) | 0x80
        let h = b.map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20).prefix(12))"
    }
    static func pairsFor(_ d: CurDev) -> [(String, String)] {
        let cdid = stableUUID("hongguo-player-cdid:" + d.did)
        let openudid = hexStr(Array(SHA256.hash(data: Data(("hongguo-player-openudid:" + d.did).utf8)).prefix(8)))
        let vc = "73932"
        return [("iid", d.iid), ("device_id", d.did), ("ac", "wifi"), ("channel", "xiaomi_8662_64"), ("aid", "8662"),
                ("app_name", "novelread"), ("cdid", cdid), ("version_code", vc), ("version_name", "7.3.9.32"),
                ("device_platform", "android"), ("os", "android"), ("ssmix", "a"), ("device_type", "23127PN0CC"),
                ("device_brand", "Xiaomi"), ("language", "zh"), ("os_api", "34"), ("os_version", "14"),
                ("manifest_version_code", vc), ("resolution", "1200*2670"), ("dpi", "460"), ("update_version_code", vc),
                ("host_abi", "arm64-v8a"), ("dragon_device_type", "phone"), ("pv_player", vc), ("compliance_status", "0"),
                ("need_personal_recommend", "1"), ("player_so_load", "1"), ("is_android_pad_screen", "0"), ("openudid", openudid)]
    }

    // MARK: - 软拒熔断 (v1.10.99, 学 iDuanJu playerBlockedUntil)
    // 现象: 连打几十枪后该出口 IP 被网关整轮 200+len=0 (换号无效, 11-20 下午真机案),
    // 继续枪林弹雨只会加深黑名单。熔断 = 全线空后熄火 5 分钟, 期间 resolve 直接劝退,
    // 文案指路飞行模式换 IP; 设置里"重置红果匿名设备"可当场清熔断。
    static let softBlockKey = "hgSoftBlockUntil"
    static var softBlocked: Bool { Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: softBlockKey) }
    static var softBlockLeft: Int { max(0, Int(UserDefaults.standard.double(forKey: softBlockKey) - Date().timeIntervalSince1970)) }
    static func softBlock(secs: Int = 300, reason: String) {
        // 只有本来就通/刚过期的口全空才值得熔断: 600s 封顶防叠罗汉
        let until = Date().timeIntervalSince1970 + Double(secs)
        if until > UserDefaults.standard.double(forKey: softBlockKey) {
            UserDefaults.standard.set(until, forKey: softBlockKey)
        }
        HGTrail.note("softblock \(secs)s \(reason)")
    }
    static func clearSoftBlock() { UserDefaults.standard.removeObject(forKey: softBlockKey) }

    // MARK: - player batch 请求 (PC 实弹 11-20 午: 1080P 五档 + spade_a)
    static let curUA = "com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; 23127PN0CC; Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)"
    static let curHosts = ["https://api5-normal-sinfonlinea.fqnovel.com",
                           "https://api5-normal-sinfonlineb.fqnovel.com",
                           "https://reading.snssdk.com"]
    static let curPath = "/novel/player/multi_video_model/player/v1"

    static func batchBody(vid: String, level: Int) -> Data? { batchBody(vids: [vid], level: level) }
    static func batchBody(vids: [String], level: Int) -> Data? {
        let obj: [String: Any] = [
            "biz_param": ["detail_page_version": 0, "device_level": level, "disable_digg_stat": false,
                          "disable_video_relate_book": false, "need_all_video_definition": true,
                          "need_mp4_align": false, "use_os_player": false, "use_server_dns": true,
                          "use_server_dns_scene": "cold_start_stage", "video_platform": 1024] as [String: Any],
            "dr_scene": "player",
            "mixed_video_id_map": ["1004": vids],
        ]
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    // 一次请求一批 vid 的取流 (真机 13:24 案: 逐集84连枪吃限流软拒 → 整剧一枪批发)
    // 每 30 集一单, 单与单间歇 2.5s; 全空则换 mint 号重试一回合
    static func attemptBatch(_ vids: [String]) async -> [String: HongguoLift.Lift] {
        var out: [String: HongguoLift.Lift] = [:]
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let body = batchBody(vids: vids, level: 4) else { return out }
        for shot in 0..<2 {
            let dev = mint()
            guard let signed = sign(pairs: pairsFor(dev), nowMillis: nowMs, deviceID: dev.did,
                                    versionName: "7.3.9.32", body: [UInt8](body)) else { continue }
            for host in curHosts {
                guard let u = URL(string: host + curPath + "?" + signed.query) else { continue }
                var req = URLRequest(url: u)
                req.httpMethod = "POST"
                req.httpBody = body
                req.setValue(curUA, forHTTPHeaderField: "User-Agent")
                for (k, v) in signed.headers where !v.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
                req.setValue("8662", forHTTPHeaderField: "x-ss-dp")
                req.setValue("101", forHTTPHeaderField: "lc")
                let ticket = Int64(signed.headers["x-ss-req-ticket"] ?? "") ?? 0
                req.setValue("\(ticket)-\(Int64(Date().timeIntervalSince1970 * 1_000_000_000) & 0x7fff_ffff)",
                             forHTTPHeaderField: "x-reading-request")
                do {
                    let (data, resp) = try await HongguoLift.direct.data(for: req)
                    let hr = resp as? HTTPURLResponse
                    let code = hr?.statusCode ?? -1
                    HGTrail.note("curl r\(shot) \(hr?.url?.host ?? "?") http=\(code) len=\(data.count) n=\(vids.count) did=\(dev.did)")
                    guard code == 200, data.count > 20,
                          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    for v in vids {
                        if out[v] == nil, let lift = HongguoLift.parseTab(j, vid: v) { out[v] = lift }
                    }
                    if !out.isEmpty { return out }
                } catch {
                    HGTrail.note("curl net " + String(String(describing: error).prefix(60)))
                }
            }
        }
        return out
    }

    static func reserve(vids: [String]) async -> [String: HongguoLift.Lift] {
        var out: [String: HongguoLift.Lift] = [:]
        var idx = 0
        while idx < vids.count {
            let chunk = Array(vids[idx..<min(idx + 30, vids.count)])
            idx += 30
            let got = await attemptBatch(chunk)
            out.merge(got) { a, _ in a }
            if got.isEmpty { HGTrail.note("reserve chunk@\(idx) 全空") }
            if idx < vids.count { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        }
        HGTrail.note("reserve done \(out.count)/\(vids.count)")
        if out.isEmpty { softBlock(reason: "reserve 0/\(vids.count)") }
        return out
    }

    /// 新方言取流: 两轮, 每轮现造新设备号 (回空=丢号重造, 绝不守死一个)
    static func attempt(vid: String) async -> HongguoLift.Lift? {
        for round in 0..<2 {
            guard let body = batchBody(vid: vid, level: 4) else { continue }
            let dev = mint()
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            guard let signed = sign(pairs: pairsFor(dev), nowMillis: nowMs, deviceID: dev.did,
                                    versionName: "7.3.9.32", body: [UInt8](body)) else {
                HGTrail.note("cur sign fail r\(round)")
                continue
            }
            for host in curHosts {
                guard let u = URL(string: host + curPath + "?" + signed.query) else { continue }
                var req = URLRequest(url: u)
                req.httpMethod = "POST"
                req.httpBody = body
                req.setValue(curUA, forHTTPHeaderField: "User-Agent")
                for (k, v) in signed.headers where !v.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
                req.setValue("8662", forHTTPHeaderField: "x-ss-dp")
                req.setValue("101", forHTTPHeaderField: "lc")
                let ticket = Int64(signed.headers["x-ss-req-ticket"] ?? "") ?? 0
                req.setValue("\(ticket)-\(Int64(Date().timeIntervalSince1970 * 1_000_000_000) & 0x7fff_ffff)",
                             forHTTPHeaderField: "x-reading-request")
                do {
                    let (data, resp) = try await HongguoLift.direct.data(for: req)
                    let hr = resp as? HTTPURLResponse
                    let code = hr?.statusCode ?? -1
                    let logid = hr?.value(forHTTPHeaderField: "x-tt-logid") ?? "-"
                    HGTrail.note("cur r\(round) \(hr?.url?.host ?? "?") http=\(code) len=\(data.count) logid=\(logid) did=\(dev.did)")
                    guard code == 200, data.count > 20,
                          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let lift = HongguoLift.parseTab(j, vid: vid) {
                        HGTrail.note("cur hit \(lift.width)x\(lift.height) def=\(lift.definition)")
                        return lift
                    }
                } catch {
                    HGTrail.note("cur net " + String(String(describing: error).prefix(60)))
                }
            }
        }
        HGTrail.note("cur miss vid=\(vid)")
        softBlock(reason: "cur miss \(vid.prefix(8))")
        return nil
    }
}
