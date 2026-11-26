import Foundation
import JavaScriptCore

// v1.10.145 换心版 — thl 官方新一代签名枪（vendor 自 sunnysky123/hongguo-web 1.3.5 公开源码包：
// thl-sign/pure-sign/util-crypto + 浏览器 buffer/base64-js/ieee754；上游谱系 THLRedGuo「官方源」11-19。
// GPL-3.0：本盒仅私人侧载自用、不分发 → 传染条款不触发，沿用盒子既有 GPL 结论）
//
// 为什么换心: 2026-11-21 起上游灰度收紧 x-medusa 整体封装(packet/extract/embed)，
// 各家手移植旧 medusa(本盒/PR#13/TV/jackotom 系)在新验桶一律 HTTP 200+0 字节——
// 这就是持续一周的「旋转门」。PC 铁证(11-25 12:0x web 1.3.5 发布 + 11-26 11:15 本仓实弹):
// pure-sign.signPlaybackV5(0..1023 抖 _rticket 至 branch0 + thl 新 medusa) 在浙江联通
// 直连「上午全灭线」打出 200+24KB 正品源 —— 解药坐实。
//
// JSC 装载链: base64-js → ieee754 → buffer(全局挂载) → thl-sign → util/crypto → pure-sign，
// require 用查表 shim；crypto 三摘要(sm3/md5/sha512)+randomBytes 反桥 Swift(HGBase 亲笔枪)。
// 桥线程模型: NSLock 全锁串行(hongguoRun 本就单任务链，锁只是保险)。
enum THLSign {
    private static let lock = NSLock()
    private static var ctx: JSContext?
    private static var broken = false

    private static func res(_ name: String) -> String? {
        guard let u = Bundle.main.url(forResource: name, withExtension: "js"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return s
    }

    private static func boot() -> JSContext? {
        if let c = ctx { return c }
        if broken { return nil }
        guard let b64 = res("jsc-base64"), let ieee = res("jsc-ieee754"),
              let buf = res("jsc-buffer"), let thl = res("jsc-thl-sign"),
              let ucryp = res("jsc-util-crypto"), let psig = res("jsc-pure-sign"),
              thl.count > 100_000, psig.count > 20_000, buf.count > 40_000,
              let c = JSContext()
        else {
            broken = true
            HGTrail.note("thl 换心装载失败: 六件套不齐")
            return nil
        }
        c.exceptionHandler = { _, e in
            HGTrail.note("thl js异常 " + String(e?.toString() ?? "-").prefix(150))
        }
        // ① Swift 反桥: 强随机 + 三摘要(hex 通道往返)
        c.setObject({ (n: JSValue) -> [NSNumber]? in
            let k = max(0, min(8192, n.toInt32()))
            return (0..<Int(k)).map { _ in NSNumber(value: Int(UInt8.random(in: 0...255))) }
        } as @convention(block) (JSValue) -> [NSNumber]?, forKeyedSubscript: "__srd" as NSString)
        c.setObject({ (algo: String, hx: String) -> String in
            var raw = [UInt8]()
            var it = hx.makeIterator()
            while let a = it.next(), let b = it.next() {
                guard let x = UInt8(String([a, b]), radix: 16) else { break }
                raw.append(x)
            }
            let d = Data(raw)
            let out: Data
            switch algo {
            case "sm3": out = HGBase.sm3Data(d)
            case "sha512": out = HGBase.sha512(d)
            default: out = HGBase.md5(d)
            }
            return out.map { String(format: "%02x", $0) }.joined()
        } as @convention(block) (String, String) -> String, forKeyedSubscript: "__hashHex" as NSString)
        // ② 全局 shim: require 查表 + module 脚手架 + crypto 垫片 + 调用出口
        c.evaluateScript("""
        var __mods = {};
        var require = function (p) {
            var m = __mods[p];
            if (!m) { throw new Error('JSC缺模块 ' + p); }
            return m;
        };
        var module = { exports: {} };
        var exports = module.exports;
        function __modBegin() { module = { exports: {} }; exports = module.exports; }
        function __modEnd(key) { if (key) { __mods[key] = module.exports; } return module.exports; }
        function __srdArr(n) { var a = __srd(n); var u = new Uint8Array(n); for (var i = 0; i < n; i++) { u[i] = a[i] & 255; } return u; }
        __mods['crypto'] = {
            randomBytes: function (n) { return Buffer.from(__srdArr(n)); },
            createHash: function (algo) {
                var acc = '';
                var h = {
                    update: function (x) {
                        acc += (typeof x === 'string') ? Buffer.from(x, 'utf8').toString('hex') : Buffer.from(x).toString('hex');
                        return h;
                    },
                    digest: function (enc) {
                        var hexs = __hashHex(algo, acc);
                        if (enc === 'hex') { return hexs; }
                        var bytes = [];
                        for (var i = 0; i < hexs.length; i += 2) { bytes.push(parseInt(hexs.substr(i, 2), 16)); }
                        return Buffer.from(bytes);
                    }
                };
                return h;
            },
            createCipheriv: function () { throw new Error('JSC crypto缺 createCipheriv'); },
            createDecipheriv: function () { throw new Error('JSC crypto缺 createDecipheriv'); }
        };
        this.__signCall = function (base, vjson, body, nowMs) {
            var values = JSON.parse(vjson);
            var r = __signV5(base, values,
                (body === null || body === undefined) ? null : Buffer.from(String(body), 'utf8'), nowMs);
            var out = { url: r.url };
            var ks = ['x-khronos', 'x-helios', 'x-medusa', 'x-ss-stub', 'Content-Type'];
            for (var i = 0; i < ks.length; i++) { out[ks[i]] = r.headers[ks[i]] || ''; }
            return out;
        };
        """)
        // ③ 六件套按序装载
        c.evaluateScript("__modBegin();")
        c.evaluateScript(b64)
        c.evaluateScript("__modEnd('base64-js');")
        c.evaluateScript("__modBegin();")
        c.evaluateScript(ieee)
        c.evaluateScript("__modEnd('ieee754');")
        c.evaluateScript("__modBegin();")
        c.evaluateScript(buf)
        c.evaluateScript("__modEnd(null); this.Buffer = module.exports.Buffer; this.SlowBuffer = module.exports.SlowBuffer; globalThis.Buffer = this.Buffer;")
        c.evaluateScript("__modBegin();")
        c.evaluateScript(thl)
        c.evaluateScript("__modEnd('./thl-sign');")
        c.evaluateScript("__modBegin();")
        c.evaluateScript(ucryp)
        c.evaluateScript("__modEnd('../util/crypto');")
        c.evaluateScript("__modBegin();")
        c.evaluateScript(psig)
        c.evaluateScript("__modEnd('./pure-sign'); var __signV5 = module.exports.signPlaybackV5;")
        let aliveV = c.evaluateScript("(typeof __signV5 === 'function') ? 'ok' : 'dead'")
        let alive = aliveV?.toString()
        guard alive == "ok" else {
            broken = true
            HGTrail.note("thl 换心装载失败: 签名入口未起")
            return nil
        }
        ctx = c
        HGTrail.note("thl 换心上机 ok js=\(thl.count + psig.count + buf.count)")
        return c
    }

    /// web 正门: base + 有序 query 参数(不含 _rticket/ts) + 明文 body(GET 传 nil) → url + 签名头
    static func signV5(base: String, values: [(String, String)], body: String?) -> (url: String, headers: [String: String])? {
        lock.lock(); defer { lock.unlock() }
        guard let c = boot() else { return nil }
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s.unicodeScalars {
                if ch == "\"" { out += "\\\"" }
                else if ch == "\\" { out += "\\\\" }
                else if ch.value < 0x20 { out += " " }
                else { out.unicodeScalars.append(ch) }
            }
            return out
        }
        let vjson = "{" + values.map { "\"\(esc($0.0))\":\"\(esc($0.1))\"" }.joined(separator: ",") + "}"
        let nowMs = NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000))
        guard let f = c.objectForKeyedSubscript("__signCall"),
              let r = f.call(withArguments: [esc(base) as NSString as Any, vjson as Any,
                                           (body.map { $0 as Any } ?? NSNull()) as Any, nowMs as Any]),
              let dict = r.toDictionary() as? [String: String],
              let url = dict["url"], !url.isEmpty
        else { return nil }
        var heads = dict
        heads.removeValue(forKey: "url")
        return (url, heads)
    }
}
