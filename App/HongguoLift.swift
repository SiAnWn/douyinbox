import Foundation
import CommonCrypto
import Compression
import Darwin

// MARK: - 信号级崩溃捕手：启动装 trap，SIGSEGV/ABRT 等把回溯纯 write 进 HGTrail 再原样重抛
enum HGCrash {
    static var fd: Int32 = -1
    static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
    static let headC: [UInt8] = Array("@@@ CRASH\n".utf8) + [0]
    static let tailC: [UInt8] = Array("@@@ END\n".utf8) + [0]
    static func install() {
        let p = SavePaths.docs.appendingPathComponent("HGTrail.txt").path
        fd = open(p, O_APPEND | O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        for sig in [SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGBUS, SIGSEGV] {
            signal(sig, hgCrashReport)
        }
    }
}
func hgCrashReport(_ sg: Int32) {
    if HGCrash.fd >= 0 {
        HGCrash.headC.withUnsafeBufferPointer { _ = write(HGCrash.fd, $0.baseAddress, HGCrash.headC.count - 1) }
        let n = backtrace(&HGCrash.frames, Int32(HGCrash.frames.count))
        if n > 0 {
            HGCrash.frames.withUnsafeMutableBufferPointer { bp in
                backtrace_symbols_fd(bp.baseAddress, n, HGCrash.fd)
            }
        }
        HGCrash.tailC.withUnsafeBufferPointer { _ = write(HGCrash.fd, $0.baseAddress, HGCrash.tailC.count - 1) }
    }
    signal(sg, SIG_DFL)
    raise(sg)
}

// MARK: - 墓碑面包屑：每阶段同步写 Documents/HGTrail.txt，闪退也留遗嘱
enum HGTrail {
    private static var bannered = false
    private static var url: URL {
        SavePaths.docs.appendingPathComponent("HGTrail.txt")
    }
    static func note(_ s: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        var line = "[" + df.string(from: Date()) + "] " + s + "\n"
        // v1.10.103 遗嘱版号横幅: 用户点名要版本入日志(每次判案先对暗号免装错版本)
        if !bannered {
            bannered = true
            let inf = Bundle.main.infoDictionary
            let v = (inf?["CFBundleShortVersionString"] as? String) ?? "?"
            let b = (inf?["CFBundleVersion"] as? String) ?? "?"
            line = "[" + df.string(from: Date()) + "] === app v" + v + " (build " + b + ") ===\n" + line
        }
        guard let d = line.data(using: .utf8) else { return }
        let f = url
        if fm.fileExists(atPath: f.path) {
            if let sz = try? fm.attributesOfItem(atPath: f.path)[.size] as? Int, sz > 200_000 {
                // 防爆：留后 80KB
                if let h = try? FileHandle(forReadingFrom: f) {
                    try? h.seek(toOffset: UInt64(max(0, sz - 80_000)))
                    let tail = (try? h.readToEnd()) ?? Data()
                    try? tail.write(to: f)
                    try? h.close()
                }
            }
            if let h = try? FileHandle(forWritingTo: f) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: d)
                try? h.close()
            }
        } else {
            try? d.write(to: f)
        }
    }
    private static let fm = FileManager.default
}

// ===================== 🍅 红果"注册身份"播放通道（借鉴 HongGuo-PC, GPL-3.0） =====================
// 背景：11 月起服务端对"每次随机临时 device_id"的匿名播放请求一律回空。
// 解法（HongGuo-PC 实证）：先向 fqnovel 日志口注册一台合法匿名手机设备（不登录），
// 再用它 + playerGorgon/Argus/Ladon 三头签名打 video_tab 口 →
// 直接回 video_list 5 档 + spade_a 内容密钥 → 走盒子现成 CENC 解密清洗。
// 所有 lift 请求走"直连会话"（蜂窝/家宽 = 中国 IP），绕开 Clash 美区出口。

// MARK: - 基础件
enum HGBase {
    /// SM3 哈希（CI SDK 无 CryptoKit.SM3，用自家移植；自检向量把关）
    static func sm3Data(_ d: Data) -> Data { HGSM3.hash(d) }
    static func md5(_ d: Data) -> Data {
        var out = Data(count: Int(CC_MD5_DIGEST_LENGTH))
        d.withUnsafeBytes { ib in
            out.withUnsafeMutableBytes { ob in
                _ = CC_MD5(ib.baseAddress, CC_LONG(d.count), ob.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return out
    }
    static func sha512(_ d: Data) -> Data {
        var out = Data(count: Int(CC_SHA512_DIGEST_LENGTH))
        d.withUnsafeBytes { ib in
            out.withUnsafeMutableBytes { ob in
                _ = CC_SHA512(ib.baseAddress, CC_LONG(d.count), ob.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return out
    }
    static func aesCBCenc(key: Data, iv: Data, data: Data) -> Data? {
        aesOp(key: key, iv: iv, data: data, enc: true, pad: true)
    }
    static func aesCBCrawEnc(key: Data, iv: Data, data: Data) -> Data? {
        aesOp(key: key, iv: iv, data: data, enc: true, pad: false)
    }
    static func aesCBCdec(key: Data, iv: Data, data: Data, pad: Bool) -> Data? {
        aesOp(key: key, iv: iv, data: data, enc: false, pad: pad)
    }
    private static func aesOp(key: Data, iv: Data, data: Data, enc: Bool, pad: Bool) -> Data? {
        let outLen = data.count + 16
        var out = Data(count: outLen)
        var moved = 0
        let st = key.withUnsafeBytes { kb in
            iv.withUnsafeBytes { ib in
                data.withUnsafeBytes { db in
                    out.withUnsafeMutableBytes { ob in
                        CCCrypt(enc ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                pad ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(0),
                                kb.baseAddress, key.count, ib.baseAddress,
                                db.baseAddress, data.count, ob.baseAddress, outLen, &moved)
                    }
                }
            }
        }
        guard st == kCCSuccess else { return nil }
        return out.subdata(in: 0..<moved)
    }
    static func hexU(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined() }
    static func hexL(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func fromHex(_ s: String) -> Data {
        var d = Data()
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next(),
              let v = UInt8(String([a, b]), radix: 16) { d.append(v) }
        return d
    }
    static func b64urlToData(_ s: String) -> Data? {
        var x = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while x.count % 4 != 0 { x += "=" }
        return Data(base64Encoded: x, options: [.ignoreUnknownCharacters])
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in d {
            c ^= UInt32(byte)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? ((c >> 1) ^ 0xedb8_8320) : (c >> 1)
            }
        }
        return ~c
    }
    static func le32(_ v: UInt32) -> Data {        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    static func be32(_ v: UInt32) -> Data {
        var x = v.bigEndian
        return Data(bytes: &x, count: 4)
    }
    static func le64(_ v: UInt64) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 8)
    }
    static func readLE64(_ d: Data, _ at: Int) -> UInt64 {
        var x: UInt64 = 0
        for i in 0..<8 { x |= UInt64(d[at + i]) << (8 * i) }
        return x
    }
    static func writeLE64(_ d: inout Data, _ at: Int, _ v: UInt64) {
        for i in 0..<8 { d[at + i] = UInt8((v >> (8 * i)) & 0xff) }
    }
    static func readBE32(_ d: Data, _ at: Int) -> UInt32 {
        (UInt32(d[at]) << 24) | (UInt32(d[at + 1]) << 16) | (UInt32(d[at + 2]) << 8) | UInt32(d[at + 3])
    }
    static func readLE32(_ d: Data, _ at: Int) -> UInt32 {
        (UInt32(d[at + 3]) << 24) | (UInt32(d[at + 2]) << 16) | (UInt32(d[at + 1]) << 8) | UInt32(d[at])
    }
    static func rotl32(_ x: UInt32, _ n: UInt32) -> UInt32 {
        let m = n & 31
        return m == 0 ? x : ((x << m) | (x >> (32 &- m)))
    }
    static func ror32(_ x: UInt32, _ n: UInt32) -> UInt32 {
        let m = n & 31
        return m == 0 ? x : ((x >> m) | (x << (32 &- m)))
    }
    static func rotl64(_ x: UInt64, _ n: UInt64) -> UInt64 {
        let m = n & 63
        return m == 0 ? x : ((x << m) | (x >> (64 &- m)))
    }
    static func ror64(_ x: UInt64, _ n: UInt64) -> UInt64 {
        let m = n & 63
        return m == 0 ? x : ((x >> m) | (x << (64 &- m)))
    }
    /// encodeURIComponent 等价：只保留 A-Za-z0-9 - _ . ! ~ * ' ( )
    static func pct(_ s: String) -> String {
        let keep = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: keep) ?? s
    }
}

// MARK: - SM3（国密哈希，argus 用；结构逐行镜像 HongGuo-PC sm3.js——abc 向量已在 PC 验证）
enum HGSM3 {
    static func hash(_ msg: Data) -> Data {
        var iv: [UInt32] = [0x7380_166f, 0x4914_b2b9, 0x1724_42d7, 0xda8a_0600,
                            0xa96f_30bc, 0x1631_38aa, 0xe38d_ee4d, 0xb0fb_0e4e]
        var data = msg
        let bitLen = UInt64(msg.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        var off = 0
        while off + 64 <= data.count {
            iv = block(data, off, iv)
            off += 64
        }
        var out = Data()
        for x in iv { out.append(contentsOf: HGBase.be32(x)) }
        return out
    }

    private static func block(_ m: Data, _ at: Int, _ v0: [UInt32]) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: 68)
        for i in 0..<16 { w[i] = HGBase.readBE32(m, at &+ i &* 4) }
        for j in 16..<68 {
            let x = w[j &- 16] ^ w[j &- 9] ^ HGBase.rotl32(w[j &- 3], 15)
            w[j] = x ^ HGBase.rotl32(x, 15) ^ HGBase.rotl32(x, 23)
                ^ HGBase.rotl32(w[j &- 13], 7) ^ w[j &- 6]
        }
        var a = v0[0], b = v0[1], c = v0[2], dd = v0[3], e = v0[4], f = v0[5], g = v0[6], h = v0[7]
        for i in 0..<64 {
            let a12 = HGBase.rotl32(a, 12)
            let tt: UInt32 = i < 16 ? 0x79cc_4519 : 0x7a87_9d8a
            let s1 = HGBase.rotl32(a12 &+ e &+ HGBase.rotl32(tt, UInt32(i)), 7)
            let s2 = s1 ^ a12
            let ff = i < 16 ? (a ^ b ^ c) : ((a & b) | (a & c) | (b & c))
            let gg = i < 16 ? (e ^ f ^ g) : ((e & f) | ((~e & 0xffff_ffff) & g))
            let t1 = ff &+ dd &+ s2 &+ (w[i] ^ w[i &+ 4])
            let t2 = gg &+ h &+ s1 &+ w[i]
            dd = c
            c = HGBase.rotl32(b, 9)
            b = a
            a = t1
            h = g
            g = HGBase.rotl32(f, 19)
            f = e
            e = t2 ^ HGBase.rotl32(t2, 9) ^ HGBase.rotl32(t2, 17)
        }
        let next = [a, b, c, dd, e, f, g, h]
        return (0..<8).map { (v0[$0] ^ next[$0]) & 0xffff_ffff }
    }
}

// MARK: - Lift 主体
enum HongguoLift {
    struct Lift {
        let url: URL
        let keyHex: String
        let definition: String
        let width: Int
        let height: Int
        let sizeBytes: Int
    }
    struct Device {
        let deviceId: String
        let iid: String
        let cdid: String
    }

    // 直连会话：connectionProxyDictionary=[:] 关掉 HTTP 代理层
    // （若手机 Clash 是 TUN/VPN 模式则此项无效，fqnovel 域名需在订阅规则里指 DIRECT）
    static let direct: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
    // v1.10.132 线路轮盘: 2026-11 画像战争时代 红果按出口分桶放行, 海外节点桶常开而国内直连常关
    // (GuoDuo 跟着系统代理就能 1080 的对照实锤) — direct 保留做第二枪
    static let viaProxy: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)   // 默认姿势 = 尊重系统代理(Clash 节点)
    }()
    // resolve 每轮换枪口: round0=viaProxy(先蹭用户节点桶) round1=direct(国内直连兜底)
    static var shot: URLSession = direct

    static var didSelfCheck = false

    // MARK: 注册设备共享池（参考同款：批量共享一个身份，回空时轮换重注一次）
    private static var cachedDevice: Device?
    static func loadStoredDevice() -> Device? {
        guard let d = UserDefaults.standard.dictionary(forKey: "hgLiftDevice"),
              let dev = d["dev"] as? String, let iid = d["iid"] as? String, let cdid = d["cdid"] as? String,
              let at = d["at"] as? TimeInterval, Date().timeIntervalSince1970 - at < 600 else { return nil }
        // v133 真凶落网: 播放口只认注册后~10分钟内的鲜号(参考文档明文) — 旧 6h 池让手机永远端着回锅老号必全空;
        // PC 版每次现注册每发必胜 vs 手机 reuse 老号 9 枪全空的同 vid 同省直连对照 = 铁证
        return Device(deviceId: dev, iid: iid, cdid: cdid)
    }
    static func device(renew: Bool = false) async throws -> Device {
        if !renew {
            if let d = cachedDevice { return d }
            if let d = loadStoredDevice() { cachedDevice = d; HGTrail.note("dev reuse saved \(d.deviceId)"); return d }
        }
        let d = try await register()
        cachedDevice = d
        UserDefaults.standard.set(["dev": d.deviceId, "iid": d.iid, "cdid": d.cdid, "at": Date().timeIntervalSince1970],
                                  forKey: "hgLiftDevice")
        return d
    }

    private static let registerURL = "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"
    private static let tabHosts = [
        "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/",
        "https://reading.snssdk.com/reading/bookapi/video_tab/multi_video_model/v1/",
    ]
    private static let registerUA = "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
    private static let tabUA = "com.phoenix.read/73532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)"
    private static let kdfSalt = HGBase.fromHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
    private static let argusKey = HGBase.fromHex("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")
    private static let argusDerived: Data = HGBase.sm3Data(HGBase.fromHex("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c") + HGBase.fromHex("3ccc567b") + HGBase.fromHex("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c"))
    private static let requestKey: [UInt8] = [68,185,185,217,164,174,249,252,164,147,170,117,124,163,194,196,164,150,147,143]

    // 设备参数（顺序严格照抓包样本：签名对 query 字节级敏感）
    private static let deviceParams: [(String, String)] = [
        ("ac", "wifi"), ("channel", "update_64"), ("aid", "8662"), ("app_name", "novelread"),
        ("version_code", "74532"), ("version_name", "7.4.5.32"),
        ("device_platform", "android"), ("os", "android"), ("ssmix", "a"),
        ("device_type", "25053RT47C"), ("device_brand", "Redmi"), ("language", "zh"),
        ("os_api", "36"), ("os_version", "16"), ("manifest_version_code", "74532"),
        ("resolution", "1280*2772"), ("dpi", "520"), ("update_version_code", "74532"),
        ("host_abi", "arm64-v8a"), ("dragon_device_type", "phone"), ("pv_player", "74532"),
        ("compliance_status", "0"), ("need_personal_recommend", "1"),
        ("player_so_load", "1"), ("is_android_pad_screen", "0"),
    ]

    // MARK: gzip（智能识别 Compression 输出：zlib 流剥壳 / 裸 deflate 直用）
    static func hgGzip(_ d: Data) throws -> Data {
        let cap = d.count + 512
        var comp = Data(count: cap)
        let n = comp.withUnsafeMutableBytes { ob in
            d.withUnsafeBytes { ib in
                compression_encode_buffer(ob.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          ib.bindMemory(to: UInt8.self).baseAddress!, d.count, nil,
                                          COMPRESSION_ZLIB)
            }
        }
        guard n > 4 else { throw GError.failed("gzip 失败") }
        comp = comp.subdata(in: 0..<n)
        var body = comp
        var mode = "raw"
        // zlib 流首字节 0x78 系（CMF/FLG 校验 %31==0）→ 剥 2 字节头 + 4 字节 adler
        if comp.count > 6, comp[0] & 0x0f == 8, (Int(comp[0]) << 8 | Int(comp[1])) % 31 == 0 {
            body = comp.subdata(in: 2..<(n - 4))
            mode = "zlib"
        }
        HGTrail.note("gz mode=" + mode + " c0=" + String(format: "%02x", comp[0]) + " n=" + String(n))
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(body)
        out.append(HGBase.le32(HGBase.crc32(d)))
        out.append(HGBase.le32(UInt32(truncatingIfNeeded: d.count)))
        return out
    }

    // MARK: 注册
    static func register() async throws -> Device {
        HGTrail.note("reg start")
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let cdid = UUID().uuidString.lowercased()
        let header: [String: Any] = [
            "display_name": "红果免费短剧", "update_version_code": 73932, "manifest_version_code": 73932,
            "app_version_minor": "7.3.9.32", "aid": 8662, "channel": "update_64", "package": "com.phoenix.read",
            "app_version": "7.3.9.32", "version_code": 73932, "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo",
            "sdk_target_version": 29, "git_hash": "3a88f4e", "os": "Android", "os_version": "16", "os_api": 36,
            "device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Redmi",
            "cpu_abi": "arm64-v8a", "release_build": "b5e187f", "density_dpi": 520, "display_density": "mdpi",
            "resolution": "1280x2772", "language": "zh", "timezone": 8, "access": "wifi", "not_request_sender": 0,
            "carrier": "CHINA MOBILE", "mcc_mnc": "46000",
            "rom": "eng.root.20231116.160340", "rom_version": "W528JS release-keys", "cdid": cdid,
            "sig_hash": "56a962410c494bbaf0b58dba20cae56f",
            "openudid": String(format: "%016llx", UInt64.random(in: 0...UInt64.max)),
            "clientudid": UUID().uuidString.lowercased(), "ipv6_list": [String](),
            "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800,
            "sim_region": "cn", "sim_serial_number": [String](), "oaid_may_support": false,
            "req_id": UUID().uuidString.lowercased(), "device_platform": "android",
            "custom": ["account_region_src": "fallback", "account_region": "cn",
                       "host_bit": 64, "dragon_device_type": "phone"],
            "pre_installed_channel": "", "apk_first_install_time": nowMs, "is_system_app": 0,
            "sdk_flavor": "china", "guest_mode": 0,
        ]
        let payload: [String: Any] = ["magic_tag": "ss_app_log", "header": header, "_gen_time": nowMs]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let gz = try hgGzip(json)
        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let derived = HGBase.sha512(HGBase.sha512(random) + kdfSalt)
        guard let ct = HGBase.aesCBCenc(key: derived.subdata(in: 0..<16),
                                        iv: derived.subdata(in: 16..<32),
                                        data: HGBase.sha512(gz) + gz) else {
            throw GError.failed("lift 注册加密失败")
        }
        var blob = HGBase.fromHex("746305100000")
        blob.append(random)
        blob.append(ct)
        var req = URLRequest(url: URL(string: registerURL)!)
        req.httpMethod = "POST"
        req.httpBody = blob
        req.setValue(registerUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/octet-stream;tt-data=a", forHTTPHeaderField: "Content-Type")
        req.setValue("gzip", forHTTPHeaderField: "log-encode-type")
        req.setValue("8662", forHTTPHeaderField: "x-ss-dp")
        req.setValue(String(nowMs), forHTTPHeaderField: "x-ss-req-ticket")
        req.setValue("4.0.3.cn", forHTTPHeaderField: "x-vc-bdturing-sdk-version")
        req.setValue("101", forHTTPHeaderField: "lc")
        req.setValue("2", forHTTPHeaderField: "sdk-version")
        req.setValue("5051452", forHTTPHeaderField: "passport-sdk-version")
        req.setValue("-8|50:51:59:30:40:47:49:39", forHTTPHeaderField: "x-neptune")
        req.setValue(HGBase.hexU(HGBase.md5(blob)), forHTTPHeaderField: "x-ss-stub")
        let (data, resp) = try await direct.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        HGTrail.note("reg http=\(code) len=\(data.count) head=" + String(decoding: data.prefix(160), as: UTF8.self).replacingOccurrences(of: "\n", with: " "))
        guard code == 200 else { throw GError.failed("lift 注册 HTTP \(code)") }
        // 大 ID 精度保护：>2^53 裸数字转字符串再解析（不伤 *_str 键）
        let rawStr = String(decoding: data, as: UTF8.self)
        var fixed = rawStr
        if let re = try? NSRegularExpression(pattern: "\"(device_id|install_id)\"[[:space:]]*:[[:space:]]*([0-9]{16,})") {
            fixed = re.stringByReplacingMatches(in: rawStr, range: NSRange(location: 0, length: rawStr.utf16.count),
                                                withTemplate: "\"$1\":\"$2\"")
        }
        let j = (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) as? [String: Any]
            ?? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func validId(_ s: String) -> Bool { s.count >= 6 && s.contains(where: \.isNumber) && !s.trimmingCharacters(in: CharacterSet(charactersIn: "0")).isEmpty }
        func bigId(_ name: String) -> String {
            if let s = j[name + "_str"] as? String, validId(s) { return s }
            if let s = j[name] as? String, validId(s) { return s }
            if let n = j[name] as? NSNumber { let s = n.stringValue; if validId(s) { return s } }
            return ""
        }
        let biz = (j["code"] as? NSNumber)?.intValue ?? (j["Code"] as? NSNumber)?.intValue ?? 0
        let dev = bigId("device_id"), iid = bigId("install_id")
        guard biz == 0, !dev.isEmpty, !iid.isEmpty else {
            HGTrail.note("reg rejected code=\(biz) dev=\(dev) iid=\(iid)")
            throw GError.failed("lift 注册被拒 code=\(biz)（出口或马甲被服务器冷待，换节点/加fqnovel直连规则再试）")
        }
        HGTrail.note("reg ok dev=\(dev) iid=\(iid)")
        return Device(deviceId: dev, iid: iid, cdid: cdid)
    }

    // MARK: 三头签名
    private static func varint(_ v: UInt64) -> Data {
        var n = v
        var out = Data()
        while n > 127 { out.append(UInt8((n & 127) | 128)); n >>= 7 }
        out.append(UInt8(n))
        return out
    }
    private static func protoVar(_ tag: Int, _ v: UInt64) -> Data {
        varint(UInt64(tag) << 3) + varint(v)
    }
    private static func protoBytes(_ tag: Int, _ d: Data) -> Data {
        varint((UInt64(tag) << 3) | 2) + varint(UInt64(d.count)) + d
    }
    private static func pad16(_ d: Data) -> Data {
        let p = 16 - (d.count % 16)
        return d + Data(repeating: UInt8(p), count: p)
    }

    private static func gorgon(query: String, khronos: UInt32) -> String {
        var payload = [UInt8](repeating: 0, count: 20)
        let qh = HGBase.md5(Data(query.utf8))
        for i in 0..<4 { payload[i] = qh[i] }
        payload[13] = 6
        payload[14] = 11
        payload[15] = 28
        let kb = HGBase.be32(khronos)
        for i in 0..<4 { payload[16 + i] = kb[i] }
        for i in 0..<20 { payload[i] ^= requestKey[i] }
        for i in 0..<20 {
            let rotated = ((payload[i] << 4) | (payload[i] >> 4)) & 0xff
            let src = UInt8(rotated ^ payload[(i + 1) % 20])
            var rev: UInt8 = 0
            for b in 0..<8 { rev |= UInt8(((src >> b) & 1) << (7 - b)) }
            payload[i] = (rev ^ 0xff ^ 20) & 0xff
        }
        return (HGBase.fromHex("8404401c0000") + Data(payload))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func argus(query: String, khronos: UInt32, deviceId: String, nonce: Data, body: Data? = nil) -> String {
        // v138: GET 空body=sm3(16零); POST 有body=sm3(md5(body)16B) — 6.30 参考 bodyHash(stubHex) 语义
        let bodyHash = HGBase.sm3Data(body.map { HGBase.md5($0) } ?? Data(repeating: 0, count: 16))
        let queryHash = HGBase.sm3Data(Data(query.utf8))
        var counters = protoVar(1, 1) + protoVar(2, 1) + protoVar(3, 1) + protoVar(7, 3_348_294_860)
        var env = protoBytes(1, Data("NX551J".utf8)) + protoVar(2, 8_196)
        env += protoVar(4, 2_162_227_200)   // 0x80e0d800 参考6.28活体形态
        var bean = Data()
        bean += protoVar(1, UInt64(0x2020_0929) &* 2)
        bean += protoVar(2, 2)
        bean += protoVar(3, UInt64(HGBase.readLE32(nonce, 6) & 0x7fff_ffff))
        bean += protoBytes(4, Data("8662".utf8))
        bean += protoBytes(5, Data(deviceId.utf8))
        bean += protoBytes(6, Data("1611921764".utf8))
        bean += protoBytes(7, Data(HGV5.queryValue(query, "version_name").utf8))
        bean += protoBytes(8, Data("v04.04.05-ov-android".utf8))
        bean += protoVar(9, 134_744_640)
        bean += protoBytes(10, Data(repeating: 0, count: 8))
        bean += protoVar(11, 0)
        bean += protoVar(12, UInt64(khronos) &* 2)
        bean += protoBytes(13, bodyHash.subdata(in: 0..<6))
        bean += protoBytes(14, queryHash.subdata(in: 0..<6))
        bean += protoBytes(15, counters)
        bean += protoBytes(16, Data())
        bean += protoBytes(20, Data("none".utf8))
        bean += protoVar(21, 738)
        bean += protoBytes(23, env)
        bean += protoVar(25, 2)
        var data = pad16(bean)
        var rounds = [UInt64](repeating: 0, count: 72)
        for i in 0..<4 { rounds[i] = HGBase.readLE64(argusDerived, i * 8) }
        for i in 4..<72 {
            let mixed = (HGBase.ror64(rounds[i - 1], 3) ^ rounds[i - 3])
                ^ HGBase.ror64(HGBase.ror64(rounds[i - 1], 3) ^ rounds[i - 3], 1)
            let bit = (0x3dc9_4c3a_046d_678b &>> UInt64((i - 4) % 62)) & 1
            rounds[i] = (~rounds[i - 4]) ^ mixed ^ (bit ^ 3)
        }
        var off = 0
        while off + 16 <= data.count {
            var left = HGBase.readLE64(data, off)
            var right = HGBase.readLE64(data, off &+ 8)
            for rd in rounds {
                let nr = left ^ ((HGBase.rotl64(right, 1) & HGBase.rotl64(right, 8))
                    ^ HGBase.rotl64(right, 2)) ^ rd
                left = right
                right = nr
            }
            HGBase.writeLE64(&data, off, left)
            HGBase.writeLE64(&data, off &+ 8, right)
            off += 16
        }
        let mask = HGBase.fromHex("d04ffdffd04ffdff")   // 8 字节！
        for i in 0..<data.count { data[i] ^= mask[i % mask.count] }
        let combined = Data((mask + data).reversed())
        let container = pad16(HGBase.fromHex("a6e783ee7001100918") + combined + HGBase.fromHex("567b"))
        let key = HGBase.md5(argusKey.subdata(in: 0..<16))
        let ivx = HGBase.md5(argusKey.subdata(in: 16..<32))
        guard let ct = HGBase.aesCBCrawEnc(key: key, iv: ivx, data: container) else { return "" }
        return (HGBase.fromHex("3ccc") + ct).base64EncodedString()
    }

    private static func ladon(aid: String, khronos: UInt32, prefix: Data) -> String {
        let digest = HGBase.md5(prefix + Data(aid.utf8))
        let ascii = Data(HGBase.hexL(digest).utf8)
        var num = HGBase.readLE64(ascii, 0)
        var value = HGBase.readLE64(ascii, 8)
        var queue = [HGBase.readLE64(ascii, 16), HGBase.readLE64(ascii, 24)]
        var rounds = [UInt64]()
        for i in 0..<34 {
            rounds.append(num)
            let next = (HGBase.ror64(value, 8) &+ num) ^ UInt64(i)
            queue.append(next)
            num = next ^ HGBase.rotl64(num, 3)
            value = queue.removeFirst()
        }
        var data = pad16(Data("\(khronos)-1611921764-\(aid)".utf8))
        var off = 0
        while off + 16 <= data.count {
            num = HGBase.readLE64(data, off)
            value = HGBase.readLE64(data, off &+ 8)
            for rd in rounds {
                value = rd ^ (num &+ HGBase.ror64(value, 8))
                num = value ^ HGBase.rotl64(num, 3)
            }
            HGBase.writeLE64(&data, off, num)
            HGBase.writeLE64(&data, off &+ 8, value)
            off += 16
        }
        return (prefix + data).base64EncodedString()
    }


    // v1.10.138 单集枪 (TV/hongguoTV 0.16.16 安卓一哥实弹图纸): POST /novel/player/video_model/v1/ + 五头签名(body 参与版)
    // 图纸要点: 版本退 73532(证明服务器也认旧号, 桶与签名才是关键) / body 明文不 gzip / 字典序 query /
    // 强制匿名 / 响应 data.video_model 三形态(dict·JSON串·base64)
    static func singleModel(vid: String, dev: Device) async -> Lift? {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let khronos = UInt32(truncatingIfNeeded: nowMs / 1000)
        let allow: Set<String> = ["ac", "channel", "aid", "app_name", "version_code", "version_name",
            "device_platform", "os", "ssmix", "device_type", "device_brand", "language", "os_api",
            "os_version", "manifest_version_code", "resolution", "dpi", "update_version_code"]
        var q: [String: String] = [:]
        for (k, v) in deviceParams where allow.contains(k) {
            if k == "version_name" { q[k] = "7.3.5.32" }
            else if k.contains("version_code") || k == "pv_player" { q[k] = "73532" }
            else { q[k] = v }
        }
        q["device_id"] = dev.deviceId
        q["iid"] = dev.iid
        q["video_id"] = vid
        let query = q.sorted { $0.key < $1.key }
            .map { HGBase.pct($0.key) + "=" + HGBase.pct($0.value) }.joined(separator: "&")
        let bodyStr = "{\"biz_param\":{\"need_all_video_definition\":true,\"video_platform\":3},\"content_type\":1,\"video_id\":\"\(vid)\"}"
        let body = Data(bodyStr.utf8)
        let nonce = Data((0..<11).map { _ in UInt8.random(in: 0...255) })
        for host in HGV5.v5Hosts {
            guard let u = URL(string: host + "/novel/player/video_model/v1/?" + query) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue(tabUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("2", forHTTPHeaderField: "Sdk-Version")
            req.setValue("0", forHTTPHeaderField: "X-XS-From-Web")
            req.setValue(HGBase.hexU(HGBase.md5(body)), forHTTPHeaderField: "x-ss-stub")
            req.setValue(String(khronos), forHTTPHeaderField: "x-khronos")
            req.setValue(gorgon(query: query, khronos: khronos), forHTTPHeaderField: "x-gorgon")
            req.setValue(argus(query: query, khronos: khronos, deviceId: dev.deviceId, nonce: nonce, body: body),
                         forHTTPHeaderField: "x-argus")
            req.setValue(ladon(aid: "8662", khronos: khronos, prefix: nonce.subdata(in: 2..<6)),
                         forHTTPHeaderField: "x-ladon")
            do {
                let (data, resp) = try await shot.data(for: req)
                let hr = resp as? HTTPURLResponse
                let code = hr?.statusCode ?? -1
                HGTrail.note("svideo \(hr?.url?.host ?? "?") http=\(code) len=\(data.count)")
                guard code == 200, data.count > 20,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      var inner = (j["data"] as? [String: Any]) else { continue }
                if let vm = inner["video_model"] {
                    var model: [String: Any]? = vm as? [String: Any]
                    if model == nil, let s = vm as? String {
                        model = (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
                            ?? (Data(base64Encoded: s).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                    }
                    if let m = model { inner = m }
                }
                if let lift = parseTab(["code": j["code"] ?? 0 as Any, "data": inner], vid: vid) {
                    HGTrail.note("svideo hit \(hr?.url?.host ?? host) \(lift.width)x\(lift.height) def=\(lift.definition)")
                    return lift
                }
            } catch { }
        }
        return nil
    }

    // MARK: tab 请求 + 解析（设备池内部自管；两口全回空 = 参考同款轮换一次）
    static func resolve(vid: String) async throws -> Lift {
        HGTrail.note("lift start vid=\(vid)")
        // v1.10.99 软拒熔断期: 熄火装死, 别再往黑名单上撞枪口
        // v1.10.136 熔断降格: 分桶轮盘时代"全空"多是号码/线路问题而非网关软拒,
        // 五分钟的旧熔断会把鲜号+双线路的自救机会整个拦死(19:27真机遗嘱实锤 left=249s 连拒两轮)
        // 新规: 只惩罚触发后头 60 秒的连珠炮, 之后放行让轮盘自己转
        if HGCurrent.softBlockLeft > 240 {
            HGTrail.note("lift softblock cold left=\(HGCurrent.softBlockLeft)s")
            throw GError.failed("红果网关刚回了个软钉子，等一分钟再投就放行（急着要就在设置里点「红果线路急救包」）")
        }
        var lastErr = "空响应"
        // v1.10.137 App 闸门塌方期快道: round0 打完(代理线 V5+新方言+五头全灭)判据——
        // 同设备直连再扫一遍 V5 性价比已极低(塌方是协议级非线路级, PC 双出口同步全空实锤),
        // 提前让位网页水闸(720 合体/360 单文件今晚实测存活), 每集少烧 ~8 秒无效轮询
        for round in 0..<2 {
            // v1.10.101 顺序重整: V5(带11-20新门)先行 — 它是当下活口; 新方言(免注册mint号)第二把交椅
            HongguoLift.shot = (round == 0) ? viaProxy : direct
            HGTrail.note("resolve round\(round) line=\(round == 0 ? "viaProxy" : "direct")")
            let dev = try await device(renew: round > 0)
            if let lift = await HGV5.attempt(vid: vid, dev: dev) {
                HGTrail.note("lift ok v5 def=\(lift.definition) \(lift.width)x\(lift.height) key=\(lift.keyHex.isEmpty ? "none" : String(lift.keyHex.prefix(8))) url=" + String(lift.url.absoluteString.prefix(90)))
                return lift
            }
            if let lift = await singleModel(vid: vid, dev: dev) {
                HGTrail.note("lift ok svideo def=\(lift.definition) \(lift.width)x\(lift.height) key=\(lift.keyHex.isEmpty ? "none" : String(lift.keyHex.prefix(8))) url=" + String(lift.url.absoluteString.prefix(90)))
                return lift
            }
            if let lift = await HGCurrent.attempt(vid: vid) {
                HGTrail.note("lift ok cur def=\(lift.definition) \(lift.width)x\(lift.height) key=\(lift.keyHex.isEmpty ? "none" : String(lift.keyHex.prefix(8))) url=" + String(lift.url.absoluteString.prefix(90)))
                return lift
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let khronos = UInt32(truncatingIfNeeded: nowMs / 1000)
            var pairs = deviceParams
            pairs.append(("device_id", dev.deviceId))
            pairs.append(("iid", dev.iid))
            pairs.append(("cdid", dev.cdid))
            pairs.append(("video_id", vid))
            pairs.append(("video_id_type", "0"))
            pairs.append(("device_level", "4"))   // v139: TV 0.16.17 实测解药 档次2→4通关(附灾民vid验收) 咱旧报1更低 一并升舱旗舰档
            pairs.append(("need_all_video_definition", "1"))
            pairs.append(("need_mp4_align", "0"))
            pairs.append(("use_os_player", "0"))
            pairs.append(("video_platform", "1024"))
            pairs.append(("source", "0"))
            pairs.append(("from_video_id", ""))
            pairs.append(("_rticket", String(nowMs)))
            let query = pairs.map { HGBase.pct($0.0) + "=" + HGBase.pct($0.1) }.joined(separator: "&")
            let nonce = Data((0..<11).map { _ in UInt8.random(in: 0...255) })
            HGTrail.note("query built len=\(query.count) dev=\(dev.deviceId)")
            var empties = 0
            for host in tabHosts {
                guard let u = URL(string: host + "?" + query) else { lastErr = "URL 构造失败"; continue }
                var req = URLRequest(url: u)
                req.setValue(tabUA, forHTTPHeaderField: "User-Agent")
                req.setValue("application/json; charset=utf-8,application/x-protobuf", forHTTPHeaderField: "Accept")
                req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                req.setValue(String(nowMs), forHTTPHeaderField: "x-ss-req-ticket")
                req.setValue(String(khronos), forHTTPHeaderField: "x-khronos")
                req.setValue(HGBase.hexU(HGBase.md5(Data())), forHTTPHeaderField: "x-ss-stub")
                HGTrail.note("tab send \(u.host ?? "?") q=\(query.count) dev=\(dev.deviceId)")
                req.setValue("0", forHTTPHeaderField: "x-xs-from-web")
                req.setValue("2", forHTTPHeaderField: "sdk-version")
                req.setValue(gorgon(query: query, khronos: khronos), forHTTPHeaderField: "x-gorgon")
                req.setValue(argus(query: query, khronos: khronos, deviceId: dev.deviceId, nonce: nonce),
                             forHTTPHeaderField: "x-argus")
                req.setValue(ladon(aid: "8662", khronos: khronos, prefix: nonce.subdata(in: 2..<6)),
                             forHTTPHeaderField: "x-ladon")
                do {
                    let (data, resp) = try await shot.data(for: req)
                    let hr = resp as? HTTPURLResponse
                    let code = hr?.statusCode ?? -1
                    let logid = hr?.value(forHTTPHeaderField: "x-tt-logid") ?? "-"
                    let hostName = hr?.url?.host ?? String(host.split(separator: "/").dropFirst(1).first ?? "?")
                    HGTrail.note("tab \(hostName) http=\(code) len=\(data.count) logid=\(logid) head=" + String(decoding: data.prefix(160), as: UTF8.self).replacingOccurrences(of: "\n", with: " "))
                    guard code == 200, data.count > 20 else {
                        if code == 200 { empties += 1 }
                        lastErr = "\(hostName) HTTP\(code) len=\(data.count)"
                        continue
                    }
                    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        lastErr = "非JSON head=" + String(decoding: data.prefix(100), as: UTF8.self)
                        continue
                    }
                    if let lift = parseTab(j, vid: vid) {
                        HGTrail.note("lift ok def=\(lift.definition) \(lift.width)x\(lift.height) key=\(lift.keyHex.isEmpty ? "none" : String(lift.keyHex.prefix(8))) url=" + String(lift.url.absoluteString.prefix(90)))
                        return lift
                    }
                    lastErr = "JSON ok 但无可用流 keys=" + j.keys.prefix(8).joined(separator: ",")
                } catch {
                    lastErr = "网络 " + String(String(describing: error).prefix(60))
                }
            }
            if empties < tabHosts.count { break }   // 非全空 = 轮换也没用，直接认输
            // v1.10.137 塌方快道: round0 三线(代理/直连同构)全空 = 协议级塌方而非线路问题
            // (今晚 PC 双出口同步全空+官网闸门存活实锤) — round1 边际价值归零, 弃枪转水闸, 每集省 ~25s
            if round == 0 {
                HGTrail.note("lift 塌方快道 弃权")
                break
            }
        }
        HGTrail.note("lift fail " + lastErr)
        // v1.10.101: 三车道(V5双门+新方言+五头)全空才算"网关不理咱", 这时才拉熔断
        HGCurrent.softBlock(reason: "全线空 " + String(lastErr.prefix(40)))
        throw GError.failed("lift: " + lastErr)
    }

    // v1.10.97 新方言 (HGCurrent) 的 item 里 video_meta/encrypt_info 可能是 JSON 字符串
    // (老 tab 口是 dict), 统一一个剥壳器给 digInt/digStr/ei 用
    private static func metaDict(_ item: [String: Any], _ field: String = "video_meta") -> [String: Any]? {
        if let m = item[field] as? [String: Any] { return m }
        if let s = item[field] as? String, let d = s.data(using: .utf8),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return m }
        return nil
    }
    private static func digInt(_ d: [String: Any], _ k: String) -> Int {
        if let n = d[k] as? NSNumber { return n.intValue }
        if let s = d[k] as? String, let dv = Double(s) { return Int(dv) }
        if let m = metaDict(d) {
            if let n = m[k] as? NSNumber { return n.intValue }
            if let s = m[k] as? String, let dv = Double(s) { return Int(dv) }
        }
        return 0
    }
    private static func digStr(_ d: [String: Any], _ k: String) -> String {
        (d[k] as? String) ?? (metaDict(d)?[k] as? String) ?? ""
    }
    // 参考假值集合 [false,0,'0','false']=明文可用; 缺失(=nil)按参考属'缺解密信息'→ 不可用
    private static func isPlainFlag(_ v: Any?) -> Bool {
        if let n = v as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return !n.boolValue }
            return n.intValue == 0
        }
        if let s = v as? String { return s == "0" || s == "false" }
        return false
    }

    static func parseTab(_ j: [String: Any], vid: String) -> Lift? {
        let biz = ((j["code"] ?? j["Code"]) as? NSNumber)?.intValue ?? 0
        guard biz == 0 else { return nil }
        guard let data = j["data"] as? [String: Any] else { return nil }
        let rows = (data["video_model_data"] as? [String: Any]) ?? data
        var entry: Any? = rows[vid] ?? data[vid]
        if entry == nil, data["video_model"] != nil { entry = data }
        guard let e = entry as? [String: Any] else { return nil }
        var model: [String: Any]?
        if let m = e["video_model"] as? [String: Any] {
            model = m
        } else if let s = e["video_model"] as? String, let d2 = s.data(using: .utf8) {
            model = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any]
        }
        guard let mo = model else { return nil }
        var vlist: [String: Any]? = mo["video_list"] as? [String: Any]
        if vlist == nil, let arr = mo["video_list"] as? [Any] {           // 参考 Object.values 兼容数组形
            vlist = Dictionary(uniqueKeysWithValues: arr.enumerated().compactMap { i, v in
                (v as? [String: Any]).map { (String(i), $0) } })
        }
        guard let vl = vlist else { return nil }
        let seed = (mo["key_seed"] as? String).flatMap { HGBase.b64urlToData($0) }
        // 时长(秒): video_duration 优先, 兼容 duration / 字符串小数
        var dur = max(digInt(mo, "video_duration"), digInt(mo, "duration"))
        if dur == 0, let s = mo["video_duration"] as? String, let dv = Double(s) { dur = Int(dv) }
        var best: Lift?
        var bestPx = 0
        for (_, raw) in vl {
            guard let item = raw as? [String: Any] else { continue }
            let codec = digStr(item, "codec_type").lowercased()
            // v1.10.97: 新方言 item 不带 codec_type (gear_des_key 标 h265), 空 codec 放行
            guard codec.isEmpty || ["h264", "avc", "avc1", "hevc", "h265", "hvc1", "hev1", "bytevc1"].contains(codec) else { continue }
            var w = digInt(item, "vwidth")
            var hh = digInt(item, "vheight")
            if w == 0 { w = digInt(item, "width") }
            if hh == 0 { hh = digInt(item, "height") }
            let px = min(w > 0 ? w : 99_999, hh > 0 ? hh : 99_999)
            var def = digStr(item, "quality_desc")
            if def.isEmpty { def = digStr(item, "definition") }
            var keyHex = ""
            let ei = metaDict(item, "encrypt_info")
            var spade = digStr(item, "spade_a")
            if spade.isEmpty, let e2 = ei { spade = (e2["spade_a"] as? String) ?? "" }
            if !spade.isEmpty { keyHex = spadeKey(spade) ?? "" }
            // 参考闸: encrypt_info.encrypt ?? item.encrypt; 无密钥而旗标又非 [false,0,'0','false'] → 密文废件跳过
            let encVal: Any? = ei?["encrypt"] ?? item["encrypt"]
            if keyHex.isEmpty && !isPlainFlag(encVal) { continue }
            var urls = [String]()
            if let m = item["main_url"] as? String { urls.append(m) }
            if let bk = item["backup_url"] as? String { urls.append(bk) }
            if let bl = item["backup_url_list"] as? [String] { urls.append(contentsOf: bl) }
            for u0 in urls {
                let media = (seed != nil) ? (spadeURL(u0, seed: seed!) ?? "") : cleanURL(u0)
                guard !media.isEmpty, let url = URL(string: media), let host = url.host,
                      host.hasSuffix("qznovelvod.com") || host.hasSuffix("fqnovelvod.com")
                        || host.hasSuffix("douyinvod.com") || host.hasSuffix("novelsite-qc.com")
                else { continue }
                if px >= bestPx {
                    // 码率: bit_rate 字段(kbps 与 bit/s 混合生态, <10万判为 kbps 折算)×时长 = 估算体积
                    var br = digInt(item, "bit_rate")
                    if br == 0 { br = digInt(item, "normalized_bit_rate") }
                    if br == 0 { br = digInt(mo, "bit_rate") }
                    if br > 0 && br < 100_000 { br &*= 1000 }
                    let est = (br > 0 && dur > 0) ? br / 8 * dur : 0
                    best = Lift(url: url, keyHex: keyHex, definition: def, width: w, height: hh, sizeBytes: est)
                    bestPx = px
                }
                break
            }
        }
        return best
    }

    // spade_a → 32hex 内容密钥（逐字节移植 deriveContentKey）
    static func spadeKey(_ value: String) -> String? {
        guard let raw = HGBase.b64urlToData(value), raw.count >= 3 else { return nil }
        var v8 = Int(raw[0]) ^ Int(raw[1]) ^ Int(raw[2])
        v8 = raw.count &- v8 &+ 47
        v8 = min(v8, raw.count &- 1)
        guard v8 >= 33 else { return nil }
        var work = raw.subdata(in: 1..<(1 &+ v8))
        var a: UInt8 = 85, b: UInt8 = 246
        for i in 0..<v8 {
            let old = work[i]
            let prev = (i & 1) != 0 ? a : b
            if (i & 1) != 0 { a = old } else { b = old }
            work[i] = UInt8(truncatingIfNeeded: (-21 - i.nonzeroBitCount + (Int(prev) ^ Int(old))))
        }
        let hexBytes = work.subdata(in: 1..<min(33, work.count))
        guard hexBytes.count == 32, let hexStr = String(data: hexBytes, encoding: .ascii) else { return nil }
        guard hexStr.allSatisfy(\.isHexDigit) else { return nil }
        return hexStr.lowercased()
    }

    // key_seed 场景的 spade 加密 URL 解密
    static func spadeURL(_ b64: String, seed: Data) -> String? {
        guard let raw = HGBase.b64urlToData(b64), raw.count >= 5,
              raw[0] == 0xa8, raw[2] == 0x01, raw[3] == 0x00 else { return nil }
        let cipherLen = ((raw.count &- 4) / 16) * 16
        guard cipherLen > 0 else { return nil }
        let h1 = HGBase.sha512(seed)
        let h2 = HGBase.sha512(h1 + kdfSalt)
        guard var plain = HGBase.aesCBCdec(key: h2.subdata(in: 0..<16), iv: h2.subdata(in: 16..<32),
                                           data: raw.subdata(in: 4..<(4 &+ cipherLen)), pad: false) else { return nil }
        if let last = plain.last, last >= 1, last <= 16, Int(last) <= plain.count {
            plain = plain.subdata(in: 0..<(plain.count &- Int(last)))
        }
        while plain.last == 0 { plain = plain.subdata(in: 0..<(plain.count - 1)) }
        return cleanURL(String(decoding: plain, as: UTF8.self))
    }

    static func cleanURL(_ v: String) -> String {
        v.replacingOccurrences(of: "\\/", with: "/")
         .replacingOccurrences(of: "\\u0026", with: "&")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: 直连下载（无进度细粒度，回报字节数即可）
    static func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue(tabUA, forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await direct.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw GError.failed("lift 下载 HTTP \(code)")
        }
        return tmp
    }

    // MARK: 首跑自检（日志核对移植正确性：sm3+三签名定点向量，哪个坏当场见光）
    static func selfCheckLine() -> String {
        var out: [String] = []
        let sm = HGBase.hexL(HGBase.sm3Data(Data("abc".utf8)))
        out.append("sm3" + (sm == "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0" ? "✓" : "✗" + sm))
        HGTrail.note("sc1 sm3 done")
        let nonce = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let k: UInt32 = 1_794_895_810
        let did = "1360575828634539"
        let g = gorgon(query: sampleQuery, khronos: k)
        out.append("gor" + (g == "8404401c0000c4c7b54fcc232d3d7022103fad22c9296abebae3" ? "✓" : "✗" + g.prefix(28)))
        HGTrail.note("sc2 gor done")
        let a = argus(query: sampleQuery, khronos: k, deviceId: did, nonce: nonce)
        out.append("arg" + (a == "8oGwZRLe2V38m+1gfqIeLa2MoV9ZBWosW5Y0NXKHAB2aEcxhwzKbdvaCLJJSxhr6ljOnA3wwt8ZlqleoPbcAySBTbZozBGYl84Hj7sC3rixtvZwcWfsom2+YXLQB5Fc52xpyMGHzOsm3+fUExh4Qf4KMU6bEbVIaK9TJ1yeZOpcvQqL9s5xVV4sMutD9Iv0XIR30Z9MWuFaxqkb69IHVHOEmjNAHsJNPqlJNOxtmJBJAq/vlOTsG+49qYFsVC8Q8JIn4rmvuAXxO9qNJRKkUGiNEjlQQPuOInW+qKlcPleMgIw==" ? "✓" : "✗" + a.prefix(40)))
        HGTrail.note("sc3 arg done")
        let l = ladon(aid: "8662", khronos: k, prefix: nonce.subdata(in: 2..<6))
        out.append("lad" + (l == "AgMEBcVLCboS0D7C+jrWMY3g/LHJpdxRfjTl94yWLoz6K/SQ" ? "✓" : "✗" + l.prefix(28)))
        HGTrail.note("sc4 lad done")
        return out.joined(separator: " ")
    }
    private static let sampleQuery = "ac=wifi&channel=update_64&aid=8662&app_name=novelread&version_code=74532&version_name=7.4.5.32&device_platform=android&os=android&ssmix=a&device_type=25053RT47C&device_brand=Redmi&language=zh&os_api=36&os_version=16&manifest_version_code=74532&resolution=1280*2772&dpi=520&update_version_code=74532&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=74532&compliance_status=0&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&device_id=1360575828634539&iid=1360575828638635&cdid=f47ac10b-58cc-4372-a567-0e02b2c3d479&video_id=7705624880623914046&video_id_type=0&device_level=1&need_all_video_definition=1&need_mp4_align=0&use_os_player=0&video_platform=1024&source=0&from_video_id=&_rticket=1794895810123"
}
