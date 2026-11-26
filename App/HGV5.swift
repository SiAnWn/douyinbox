import Foundation
import CommonCrypto

// MARK: - 红果 V5 播放协议（移植 openhongguo PR#13 / superhuluwa @788103f6，逐字节镜像）
// 门相：POST {host}/novel/player/multi_video_model/player/v1?query
//   query = 74332/7.4.3.32/vivo_8662_64/PGT-AN10/Android12 模板 + 注册身份(iid,cdid,device_id) + _rticket(搜 1024 至 iv&15==12)
//   body  = 排序键 JSON → gzip，签名与发送用同一份字节
//   签名  = x-khronos + x-helios(V5) + x-medusa(V5) + x-ss-stub(大写MD5)，无 argus/ladon/gorgon
enum HGV5 {
    // ---- 常量（线格式公开值，照抄 playback_v5_constants.go / f13.go）----
    static let license = "646637794"
    // PR#17 (11-20 下午): 服务端把 player 段从路径搬进 body(dr_scene), 旧门 200 空体骗人
    // 新门优先, 旧门留备胎 (服务端若回撤还能活)
    static let pathNew = "/novel/player/multi_video_model/v1/"
    static let path = "/novel/player/multi_video_model/player/v1"
    // 6.28 实证: 2026-11-24 起红果拒 74332 画像, preload/v1 + 74532 + medusa field21=312 三件套同时满足才发货
    static let pathPre = "/novel/player/multi_video_model/preload/v1"
    static let v5UA = "com.phoenix.read/74532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
    static let magic = HGBase.fromHex("2d4b4fca49750d433fb5ae2c226dcc56")
    static let signKey = HGBase.fromHex("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d")
    static let v5Sbox = HGBase.fromHex(
        "53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d" +
        "f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a" +
        "80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d" +
        "d12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912" +
        "38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65" +
        "b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe" +
        "1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8" +
        "94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc" +
        "d759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d" +
        "e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e" +
        "47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28" +
        "8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5" +
        "d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9" +
        "1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f" +
        "d830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168" +
        "1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e")
    static let branch0TT: [UInt32] = [
        0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
        0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
        0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
        0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
        0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
        0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
        0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
        0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586]
    static let branch0Init: [UInt32] = [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264]

    // ---- 进程级签名者（started+nonce 全生命周期稳定，同 PR 的 PlaybackV5Signer）----
    static var startedMs: Int64 = 0
    static var nonceB64 = ""
    static func ensureSigner() {
        guard startedMs == 0 else { return }
        startedMs = Int64(Date().timeIntervalSince1970 * 1000)
        let n = Data((0..<18).map { _ in UInt8.random(in: 0...255) })
        nonceB64 = n.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    struct Entropy { let messageRandom: UInt32, random: UInt32, packedRandom: UInt32, heliosRandom: UInt32 }
    static func drawEntropy() -> Entropy {   // 同 request.go drawEntropy 的 16 字节读法(12:16 与 12:14 重叠)
        let b = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return Entropy(messageRandom: HGBase.readLE32(b, 0), random: HGBase.readLE32(b, 4),
                       packedRandom: HGBase.readLE32(b, 8), heliosRandom: HGBase.readLE32(b, 12))
    }

    static func v5Pairs(_ dev: HongguoLift.Device) -> [(String, String)] {
        [("aid", "8662"), ("app_name", "novelread"),
         ("version_code", "74532"), ("version_name", "7.4.5.32"),
         ("channel", "update_64"), ("device_brand", "Redmi"), ("device_platform", "android"),
         ("device_type", "25053RT47C"), ("os_version", "16"), ("os_api", "36"), ("update_version_code", "74532"),
         ("iid", dev.iid), ("cdid", dev.cdid), ("device_id", dev.deviceId)]
    }

    static func v5Body(vid: String) -> Data? {   // Go map 序列化=键名字典序；gzip 一次、签名与发送同字节
        let json = "{\"biz_param\":{\"detail_page_version\":0,\"device_level\":2,\"disable_digg_stat\":false," +
            "\"disable_video_relate_book\":false,\"need_all_video_definition\":true,\"need_mp4_align\":false," +
            "\"use_os_player\":false,\"use_server_dns\":false,\"video_platform\":1024},\"dr_scene\":\"preload\"," +
            "\"mixed_video_id_map\":{\"1004\":[\"\(vid)\"]}}"
        return try? HongguoLift.hgGzip(Data(json.utf8))
    }

    // v1.10.101 批发预订单 V5 方言版 (PC 16:5x 实测新门 mixed 形态 = 5 流+密钥 23690B)
    static func v5BodyBatch(vids: [String]) -> Data? {
        let arr = vids.map { "\"\($0)\"" }.joined(separator: ",")
        let json = "{\"biz_param\":{\"detail_page_version\":0,\"device_level\":2,\"disable_digg_stat\":false," +
            "\"disable_video_relate_book\":false,\"need_all_video_definition\":true,\"need_mp4_align\":false," +
            "\"use_os_player\":false,\"use_server_dns\":false,\"video_platform\":1024},\"dr_scene\":\"preload\"," +
            "\"mixed_video_id_map\":{\"1004\":[\(arr)]}}"
        return try? HongguoLift.hgGzip(Data(json.utf8))
    }

    static func reserve(vids: [String], dev: HongguoLift.Device) async -> [String: HongguoLift.Lift] {
        var out: [String: HongguoLift.Lift] = [:]
        guard let body = v5BodyBatch(vids: vids),
              let signed = sign(pairs: v5Pairs(dev), nowMs: Int64(Date().timeIntervalSince1970 * 1000), body: body) else { return out }
        for host in v5Hosts {
          for p in [pathPre, pathNew, path] {
            guard let u = URL(string: host + p + "?" + signed.query) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue(v5UA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (k, v) in signed.headers { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await HongguoLift.shot.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                HGTrail.note("v5res \(host) p=\(p.hasSuffix("/v1/") ? "new" : "old") http=\(code) len=\(data.count) n=\(vids.count)")
                guard code == 200, data.count > 20,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var jd = (j["data"] as? [String: Any]) ?? [:]
                if let g = jd["1004"] as? [String: Any] { jd = g }
                for v in vids where out[v] == nil {
                    if let lift = HongguoLift.parseTab(["code": 0 as NSNumber, "data": jd], vid: v) { out[v] = lift }
                }
                if !out.isEmpty { return out }
            } catch {
                HGTrail.note("v5res net " + String(String(describing: error).prefix(60)))
            }
          }
        }
        return out
    }

    // ---- 原语 ----
    static func getIV(_ iv: UInt32, _ data: Data) -> UInt32 {
        var value = iv
        for (i, bb) in data.enumerated() {
            if i & 1 == 0 {
                value = (value >> 4) ^ value ^ (value << 6) ^ UInt32(bb)
            } else {
                let inner = (value >> 7) ^ value ^ (UInt32(bb) | (value << 12))
                value = ~inner
            }
        }
        return value
    }

    static func sumMD5(_ data: [UInt8]) -> UInt32 {
        var check = UInt32(0x20220420)
        for i in 0..<12 {
            var temp: UInt32
            if i & 1 == 0 {
                temp = (check >> 3) ^ check
                check = UInt32(data[i]) ^ (check << 7)
            } else {
                temp = (check >> 5) ^ check
                check = UInt32(data[i]) | (check << 11)
                check = ~check
            }
            check ^= temp
        }
        return (check | 4) ^ 0x01000000
    }

    static func expandWords(_ data: Data) -> [UInt32] {
        var di: [UInt32] = []
        var off = 0
        while off + 4 <= data.count { di.append(HGBase.readBE32(data, off)); off += 4 }
        guard di.count >= 16 else { return di }
        var d0 = di[0]
        for i in 0..<112 {
            let d1 = di[i + 1]
            let d14 = di[i + 14]
            let r1 = HGBase.rotl32(d1, 14) ^ HGBase.rotl32(d1, 25) ^ (d1 >> 3)
            let r2 = HGBase.rotl32(d14, 13) ^ HGBase.rotl32(d14, 15) ^ (d14 >> 10)
            di.append(d0 &+ di[i + 9] &+ r1 &+ r2)
            d0 = d1
        }
        return di
    }

    static func mixRounds(_ stateIn: [UInt32], _ rounds: [UInt32], _ di: [UInt32], _ tt: [UInt32], _ ivV1: UInt32) -> [UInt32] {
        var state = stateIn
        for i in UInt32(0)..<rounds[0] {
            let base = ivV1 &+ i
            let w = di[Int(base & 127)]
            let idx = { (k: Int) -> Int in Int(rounds[k]) }
            let n1 = ((state[idx(3)] ^ state[idx(4)]) & state[idx(1)]) ^ state[idx(3)]
            let n2 = HGBase.rotl32(state[idx(1)], 26) ^ HGBase.rotl32(state[idx(1)], 21) ^ HGBase.rotl32(state[idx(1)], 7)
            let n4 = w &+ n1 &+ n2 &+ tt[Int(base & 63)] &+ state[idx(5)]
            let n5 = HGBase.rotl32(state[idx(2)], 30) ^ HGBase.rotl32(state[idx(2)], 19) ^ HGBase.rotl32(state[idx(2)], 10)
            let n6 = (state[idx(2)] & state[idx(6)]) | ((state[idx(2)] | state[idx(6)]) & state[idx(7)])
            let n7 = n5 &+ n6
            let old = state[idx(9)]
            let last = state[state.count - 1]
            state = [last] + Array(state[0..<state.count - 1])
            state[idx(10)] = n7 &+ n4
            state[idx(8)] = old &+ n4
        }
        return state
    }

    static func v5Hash(queryHash: Data, bodyMD5: Data, ts: UInt32) -> Data {
        let seed = UInt32(0x9d4a97c2)
        let count = seed &+ ts
        let table = branch0TT.map { HGBase.ror32($0, count &+ 1) }
        var pad = [UInt8]()
        for v: UInt8 in [0xfa, 0x45, 0x61, 0xd7] {
            let combined = UInt16(v) | (UInt16(v) << 8)
            pad.append(UInt8(truncatingIfNeeded: combined >> UInt16((count &+ 2) & 7)))
        }
        let input = queryHash + bodyMD5 + HGBase.le32(ts) + Data(pad) + Data([0, 0, 0, 0, 0, 0, 1, 0xa0])
        let words = expandWords(input)
        let initial = branch0Init.map { HGBase.ror32($0, count) }
        let state = mixRounds(initial, [96, 1, 3, 4, 0, 6, 5, 2, 0, 7, 7], words, table, seed)
        var result = Data()
        for i in 0..<8 { result.append(contentsOf: HGBase.be32(state[i] &+ initial[i])) }
        for i in 0..<16 { result[i] ^= result[16 + i] }
        let head = Array(result[0..<16])
        return result.subdata(in: 0..<16) + HGBase.le32(sumMD5(head) | 0x20)
    }

    static func keyHash(_ random: UInt32) -> (Data, Data) {
        let buf = signKey + HGBase.le32(random) + signKey
        let hash = HGBase.sm3Data(buf)
        let d1 = UInt8((random >> 16) & 255)
        var d2 = (UInt32(d1) << 11) | (random >> 24)
        d2 ^= UInt32(d1) >> 5
        d2 ^= UInt32(d1)
        d2 = ~d2
        return (hash, HGBase.le32(d2))
    }

    static func xmxor(_ dataIn: [UInt8], _ key: [UInt8]) -> [UInt8] {
        let n = dataIn.count
        var encoded = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let at = (i * 4) & 28
            let d0 = key[at], d1 = key[at + 1]
            let rv = (dataIn[i] << 4) | (dataIn[i] >> 4)
            var d2 = UInt8(truncatingIfNeeded: UInt32(rv) &+ UInt32(d0))
            d2 = (~d2) ^ d1
            d2 = (d2 << 3) | (d2 >> 5)
            d2 = d2 &+ d1
            d2 = d2 ^ d0
            encoded[n - i - 1] = ~d2
        }
        let last = encoded[n - 1] ^ encoded[n - 2]
        let first = encoded[0]
        encoded[0] = (~last) &+ first
        encoded[1] = (encoded[0] ^ encoded[n - 1] ^ 254) &+ encoded[1]
        let shifted = (encoded[1] << 3) | (encoded[1] >> 5)
        let fix2 = (last &- first) ^ (shifted ^ 2)
        encoded[2] = encoded[2] &+ fix2
        for i in 0..<(n - 4) {
            let sh = (encoded[i + 2] << 3) | (encoded[i + 2] >> 5)
            let temp = sh ^ encoded[i + 1] ^ UInt8(truncatingIfNeeded: i + 3)
            encoded[i + 3] = (~temp) &+ encoded[i + 3]
        }
        encoded[n - 1] = encoded[n - 1] ^ encoded[n - 2]
        var sum = UInt32(0)
        for item in encoded[1...] { sum &+= UInt32(item) }
        encoded[0] = (encoded[0] ^ encoded[1]) &+ UInt8(truncatingIfNeeded: sum)
        return encoded
    }

    static func diffuseWords(_ words: [UInt64]) -> [UInt64] {
        var table = [words[0]]
        var b0 = words[0], b8 = words[1]
        var queue = Array(words[2...])
        for i in UInt64(0)..<34 {
            var x8 = (HGBase.ror64(b8, 8) &+ b0) ^ i
            queue.append(x8)
            x8 = x8 ^ HGBase.ror64(b0, 61)
            table.append(x8)
            b0 = x8
            b8 = queue.removeFirst()
        }
        return table
    }

    static func heliosV5(ts: UInt32, random: UInt32) -> String {
        let seed = HGBase.le32(random) + Data("8662".utf8)
        let ascii = Data(HGBase.hexL(HGBase.md5(seed)).utf8)
        var words = [UInt64]()
        for i in 0..<4 { words.append(HGBase.readLE64(ascii, i * 8)) }
        let table = diffuseWords(words)
        var text = Array("\(ts)-\(license)-8662".utf8)
        let padding = UInt8(16 - text.count % 16)
        for _ in 0..<Int(padding) { text.append(padding) }
        var out = Array(HGBase.le32(random))
        var at = 0
        while at < text.count {
            var a = HGBase.readLE64(Data(text), at)
            var b = HGBase.readLE64(Data(text), at + 8)
            for key in table[0..<34] {
                b = key ^ (a &+ HGBase.ror64(b, 8))
                a = b ^ HGBase.ror64(a, 61)
            }
            out.append(contentsOf: HGBase.le64(a))
            out.append(contentsOf: HGBase.le64(b))
            at += 16
        }
        return Data(out).base64EncodedString()
    }

    // ---- proto（protoBytes 空体=整个字段省略，同 Go）----
    static func pVar(_ v: UInt64) -> [UInt8] {
        var n = v, o = [UInt8]()
        while n > 127 { o.append(UInt8(n & 127) | 128); n >>= 7 }
        o.append(UInt8(n)); return o
    }
    static func pBytes(_ tag: UInt32, _ b: [UInt8]) -> [UInt8] {
        if b.isEmpty { return [] }
        return pVar((UInt64(tag) << 3) | 2) + pVar(UInt64(b.count)) + b
    }
    static func pStr(_ tag: UInt32, _ s: String) -> [UInt8] { pBytes(tag, Array(s.utf8)) }
    static func pSInt(_ tag: UInt32, _ v: Int64) -> [UInt8] {
        pVar(UInt64(tag) << 3) + pVar(UInt64((v << 1) ^ (v >> 63)))
    }

    static func queryValue(_ query: String, _ name: String) -> String {
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, String(kv[0]) == name else { continue }
            let v = String(kv[1])
            return v.removingPercentEncoding ?? v
        }
        return ""
    }

    // ---- medusa V5 组装 ----
    static func medusa(query: String, queryHash: Data, bodyMD5: Data, ts: UInt32, ent: Entropy) -> String {
        let deviceID = queryValue(query, "device_id")
        let version = queryValue(query, "version_name")
        let device: [UInt8] =
            pSInt(1, 1) + pSInt(2, 2) + pStr(3, "8662") + pStr(4, deviceID) +
            pStr(5, nonceB64) + pStr(6, "!noperm!") + pStr(12, "Asia/Shanghai,8") +
            pStr(13, "zh_CN") + pStr(14, queryValue(query, "os_version")) + pSInt(25, startedMs) +
            pStr(30, queryValue(query, "device_type")) + pStr(31, "HONOR") +
            pStr(32, queryValue(query, "device_type")) + pStr(34, "HONOR")
        let env: [UInt8] = pStr(6, "v04.10.03.04-bugfix") + pStr(8, queryValue(query, "channel")) +
            pBytes(12, device) + pStr(14, version)
        let digest = v5Hash(queryHash: queryHash, bodyMD5: bodyMD5, ts: ts)
        let flags = [UInt8](repeating: 0, count: 8)
        let message: [UInt8] =
            pBytes(1, Array(magic)) + pSInt(2, 5) + pSInt(3, Int64(ent.messageRandom)) +
            pStr(4, "8662") + pStr(5, deviceID) + pStr(6, license) +
            pStr(7, version) + pStr(8, "v04.10.03-ml-android") + pSInt(9, 0x040a0300) +
            pBytes(10, flags) + pSInt(12, Int64(ts)) + pBytes(13, Array(digest)) + pBytes(14, Array(queryHash[0..<6])) +
            pBytes(15, pSInt(1, 1) + pSInt(2, 1) + pSInt(3, 1) + pSInt(5, 1)) +
            pSInt(17, Int64(ts)) + pStr(20, "none") + pSInt(21, 312) + pBytes(23, env) +
            pStr(24, "{\"cmr\":16777216,\"cmr2\":16777216,\"un_h\":11,\"vpn\":0,\"kd\":0,\"dyn\":\"\",\"do\":1,\"tk\":true}")
        let (hash, mask) = keyHash(ent.random)
        var transformed = flags + xmxor(message, Array(hash))
        transformed = Array(transformed.reversed())
        for i in 0..<transformed.count { transformed[i] ^= mask[(~i) & 3] }
        var check = UInt32(0x18000001)
        check |= UInt32(queryHash[queryHash.startIndex] & 63) << 14
        check |= UInt32(digest[digest.startIndex] & 63) << 8
        var packed: [UInt8] = [0xca] + Array(HGBase.le32(ent.packedRandom)) + Array(HGBase.le32(check)) + transformed
        packed.append(UInt8(truncatingIfNeeded: ent.random >> 16))
        packed.append(UInt8(truncatingIfNeeded: ent.random >> 24))
        let key = HGBase.md5(signKey.subdata(in: 0..<16))
        let iv = HGBase.md5(signKey.subdata(in: 16..<32))
        let encrypted = encryptV5(packed, Array(key), Array(iv), ts)
        var prefix = Array(HGBase.le32(5)) + Array(magic)
        for i in 0..<prefix.count { prefix[i] ^= UInt8(truncatingIfNeeded: ts >> (UInt32(i & 3) * 8)) }
        let result = prefix + [UInt8(truncatingIfNeeded: ent.random), UInt8(truncatingIfNeeded: ent.random >> 8), 0, 1] + encrypted
        return Data(result).base64EncodedString()
    }

    // ---- V5 专用 AES（aesV3 变体：playbackV5Sbox + 专有 con2/order/initial + 位散布）----
    static func expandAESWith(_ key: [UInt8], _ initial: UInt32, _ box: [UInt8]) -> [[UInt8]] {
        var initialBytes = [UInt8]()
        let le = Array(HGBase.le32(initial))
        for _ in 0..<4 { initialBytes.append(contentsOf: le) }
        var expanded = [UInt8]()
        for i in 0..<16 { expanded.append(initialBytes[i] ^ key[i]) }
        expanded.append(contentsOf: [UInt8](repeating: 0, count: 32))
        var rounds = UInt32(8)
        for i in 4..<12 {
            let at = 4 * (i - 1)
            var a = expanded[at], b = expanded[at + 1], c = expanded[at + 2], d = expanded[at + 3]
            if i & 3 == 0 {
                let t = UInt8(truncatingIfNeeded: ((initial >> (rounds & 24)) ^ UInt32(box[Int(b)])) & 255)
                b = box[Int(c)]
                c = box[Int(d)]
                d = box[Int(a)]
                a = t
            }
            rounds &+= 2
            expanded[at + 4] = a ^ expanded[at - 12]
            expanded[at + 5] = b ^ expanded[at - 11]
            expanded[at + 6] = c ^ expanded[at - 10]
            expanded[at + 7] = d ^ expanded[at - 9]
        }
        var keys = [[UInt8]]()
        for i in 0..<12 { keys.append(Array(expanded[i * 4..<(i * 4 + 4)])) }
        return keys
    }

    static func blockV5(_ value: [UInt8], _ box: [UInt8], _ con2: [Int], _ order: [Int], _ keys: [[UInt8]]) -> [UInt8] {
        var state = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: 4)
        for i in 0..<4 { for j in 0..<4 { state[i][j] = value[i * 4 + j] } }
        func addCon(_ r: Int) { for i in 0..<4 { for j in 0..<4 { state[i][j] ^= keys[r + i][con2[j]] } } }
        addCon(0)
        for i in 1..<3 {
            var old = state
            for a in 0..<4 { for b in 0..<4 { old[a][b] = box[Int(state[a][b])] } }
            for a in 0..<4 { state[a] = old[con2[a]] }
            var flat = [UInt8]()
            for a in 0..<4 { flat.append(contentsOf: state[a]) }
            for k in 0..<16 { state[k / 4][k % 4] = flat[order[k]] }
            if i == 1 {
                old = state
                for a in 0..<4 { for b in 0..<4 { state[a][b] = old[a][con2[b]] } }
                func xt(_ x: UInt8) -> UInt8 { var v = UInt8(truncatingIfNeeded: Int(x) << 1); if x & 128 != 0 { v ^= 0x1b }; return v }
                for col in 0..<4 {
                    let t = state[0][col] ^ state[1][col] ^ state[2][col] ^ state[3][col]
                    let u = state[0][col]
                    state[0][col] ^= t ^ xt(state[0][col] ^ state[1][col])
                    state[1][col] ^= t ^ xt(state[1][col] ^ state[2][col])
                    state[2][col] ^= t ^ xt(state[2][col] ^ state[3][col])
                    state[3][col] ^= t ^ xt(state[3][col] ^ u)
                }
            }
            addCon(i * 4)
        }
        for i in 0..<4 { for j in 0..<4 { state[i][j] ^= keys[4 + i][j] } }
        var out = [UInt8]()
        for i in 0..<4 { out.append(contentsOf: state[i]) }
        return out
    }

    static func xorCyclic(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = a
        for i in 0..<out.count { out[i] ^= b[i % b.count] }
        return out
    }

    static func encryptV5(_ data: [UInt8], _ key: [UInt8], _ iv: [UInt8], _ ts: UInt32) -> [UInt8] {
        let word = Int(ts & 3)
        let box = Array(v5Sbox[word * 256..<(word + 1) * 256])
        let initial: UInt32 = [0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9][word]
        let con2 = [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]][word]
        let order = [
            [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
            [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
            [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
            [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7]][word]
        let keys = expandAESWith(key, initial, box)
        let wire = [6, 5, 3, 4, 2, 7, 1, 0]
        let compact = [1, 7, 3, 6, 2, 0, 4, 5]
        var plain = [UInt8](repeating: 0, count: 32)
        for i in 0..<31 {
            for j in 0..<8 {
                let at = i * 8 + j
                if at < data.count {
                    plain[i] |= UInt8(truncatingIfNeeded: ((Int(data[at]) >> wire[j]) & 1) << compact[j])
                }
            }
        }
        plain[31] = 1
        let first = blockV5(xorCyclic(Array(plain[0..<16]), iv), box, con2, order, keys)
        let second = blockV5(xorCyclic(Array(plain[16..<32]), first), box, con2, order, keys)
        let bits = first + second
        var out = data
        for i in 0..<31 {
            for j in 0..<8 {
                let at = i * 8 + j
                if at < out.count {
                    let clear = UInt8(truncatingIfNeeded: ~(1 << wire[j]))
                    let set = UInt8(truncatingIfNeeded: ((Int(bits[i]) >> compact[j]) & 1) << wire[j])
                    out[at] = (out[at] & clear) | set
                }
            }
        }
        return [bits[31]] + out
    }

    // ---- 签名 + 请求 ----
    static func sign(pairs: [(String, String)], nowMs: Int64, body: Data) -> (query: String, headers: [String: String])? {
        let ts = UInt32(truncatingIfNeeded: nowMs / 1000)
        let bodyMD5 = HGBase.md5(body)
        for offset in Int64(0)..<1024 {
            let ticket = nowMs &+ offset
            var withT = pairs
            withT.append(("_rticket", String(ticket)))
            let query = withT.map { HGBase.pct($0.0) + "=" + HGBase.pct($0.1) }.joined(separator: "&")
            let queryHash = HGBase.sm3Data(Data(query.utf8))
            let iv = getIV(getIV(getIV(0x20230928, queryHash), bodyMD5), HGBase.le32(ts))
            if iv & 15 != 12 { continue }
            let ent = drawEntropy()
            let headers: [String: String] = [
                "x-khronos": String(ts),
                "x-helios": heliosV5(ts: ts, random: ent.heliosRandom),
                "x-medusa": medusa(query: query, queryHash: queryHash, bodyMD5: bodyMD5, ts: ts, ent: ent),
                "Content-Type": "application/json; charset=utf-8",
                "x-ss-stub": HGBase.hexU(bodyMD5),
            ]
            return (query, headers)
        }
        return nil
    }

    static let v5Hosts = [
        "https://reading.snssdk.com",
        "https://api5-normal-sinfonlineb.fqnovel.com",
        "https://api5-normal-sinfonlinea.fqnovel.com",
        // v1.10.138 军火版: jackotom 8.3 策略包 + TV 0.16.16 图纸新增两域 (桶旋转时多俩抽奖口)
        "https://api5-normal-sinfonlinec.fqnovel.com",
        "https://api3-normal-sinfonlinea.fqnovel.com",
    ]

    // ==== v1.10.145 换心主炮: web 1.3.5 正门三件套 (73932族 + 单集接口 + 明文JSON + thl签名) ====
    static let thlSinglePath = "/novel/player/video_model/v1/"
    static let thlUA = "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"

    static func thlFam(vid: String, dev: HongguoLift.Device) -> [(String, String)] {
        [("aid", "8662"), ("app_name", "novelread"), ("version_code", "73932"), ("version_name", "7.3.9.32"),
         ("channel", "update_64"), ("device_platform", "android"), ("device_type", "NX551J"), ("device_brand", "nubia"),
         ("os", "android"), ("ssmix", "a"), ("language", "zh"), ("os_api", "35"), ("os_version", "15"),
         ("resolution", "1080"), ("dpi", "480"), ("manifest_version_code", "73932"), ("update_version_code", "73932"),
         ("ac", "wifi"), ("device_id", dev.deviceId), ("iid", dev.iid),
         ("video_id", vid), ("video_platform", "3")]
    }

    static func thlAttempt(vid: String, dev: HongguoLift.Device) async -> HongguoLift.Lift? {
        let body = "{\"biz_param\":{\"device_level\":3,\"need_all_video_definition\":true,\"video_platform\":3},\"content_type\":1,\"video_id\":\"" + vid + "\"}"
        var empty = 0
        for host in v5Hosts {
            guard let s5 = THLSign.signV5(base: host + thlSinglePath, values: thlFam(vid: vid, dev: dev), body: body),
                  let u = URL(string: s5.url) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.httpBody = Data(body.utf8)
            req.setValue(thlUA, forHTTPHeaderField: "User-Agent")
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (k, v) in s5.headers where !v.isEmpty && k != "url" { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await HongguoLift.shot.data(for: req)
                let hr = resp as? HTTPURLResponse
                let code = hr?.statusCode ?? -1
                HGTrail.note("thlv5 \(hr?.url?.host ?? "?") http=\(code) len=\(data.count)")
                guard code == 200, data.count > 20,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { empty += 1; continue }
                var inner = (j["data"] as? [String: Any]) ?? [:]
                // 单集形态三兼容解包(承 138 singleModel 图纸): video_model = dict / JSON串 / base64
                if let vm = inner["video_model"] as? String {
                    var payload = Data(vm.utf8)
                    if !vm.hasPrefix("{"), let dec = Data(base64Encoded: vm) { payload = dec }
                    if let m = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] { inner["video_model"] = m }
                } else if inner["video_model"] == nil, let g = inner["1004"] as? [String: Any] {
                    inner = (g[vid] as? [String: Any]) ?? g
                }
                if let lift = HongguoLift.parseTab(["code": j["code"] ?? 0 as NSNumber, "data": inner], vid: vid) {
                    HGTrail.note("thlv5 换心命中 \(hr?.url?.host ?? host) \(lift.width)x\(lift.height)")
                    return lift
                }
                empty += 1
            } catch {
                HGTrail.note("thlv5 哑 \(String(describing: error).prefix(60))")
            }
        }
        if empty > 0 { HGTrail.note("thlv5 全线空\(empty)口 落旧炮") }
        return nil
    }



    static func attempt(vid: String, dev: HongguoLift.Device) async -> HongguoLift.Lift? {
        ensureSigner()
        // v1.10.145 换心版: thl 官方新封装 medusa 首炮(PC 11:15 铁证 24KB), 五口轮完落旧炮
        if UserDefaults.standard.object(forKey: "hgThlOff") == nil,
           let lift = await thlAttempt(vid: vid, dev: dev) { return lift }
        guard let body = v5Body(vid: vid), let signed = sign(pairs: v5Pairs(dev), nowMs: Int64(Date().timeIntervalSince1970 * 1000), body: body) else {
            HGTrail.note("v5 sign fail")
            return nil
        }
        HGTrail.note("v5 signed q=\(signed.query.count) stub=\(signed.headers["x-ss-stub"]?.prefix(8) ?? "-")")
        for host in v5Hosts {
          for p in [pathPre, pathNew, path] {   // 新门(player搬走后)优先, 旧门兜底
            guard let u = URL(string: host + p + "?" + signed.query) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue(v5UA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (k, v) in signed.headers { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await HongguoLift.shot.data(for: req)
                let hr = resp as? HTTPURLResponse
                let code = hr?.statusCode ?? -1
                let logid = hr?.value(forHTTPHeaderField: "x-tt-logid") ?? "-"
                HGTrail.note("v5 \(hr?.url?.host ?? "?") http=\(code) len=\(data.count) logid=\(logid)")
                guard code == 200, data.count > 20,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var inner: [String: Any] = (j["data"] as? [String: Any]) ?? [:]
                if let g = inner["1004"] as? [String: Any] { inner = g }
                if inner["video_model"] == nil, let row = inner[vid] as? [String: Any] { inner = row }
                if let lift = HongguoLift.parseTab(["code": 0 as NSNumber, "data": inner], vid: vid) {
                    HGTrail.note("v5 hit \(hr?.url?.host ?? host) \(lift.width)x\(lift.height)")
                    return lift
                }
            } catch {
                HGTrail.note("v5 net " + String(String(describing: error).prefix(60)))
            }
          }   // for p 双门
        }
        return nil
    }
}
