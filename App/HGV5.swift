import Foundation

// v1.10.150 大扫版 — HGV5 瘦身为只剩 thl 换心主炮（12:59 用户钦点: 剔 720 水闸、清废弃代码）
//
// 阵亡名单（源码可考 git history @26a0bd6，此三类再未被信任的握手救回）:
//   · 1.9.41 手移植 Go PR#13 炮 (preload mixed + 自制 v5 medusa, getIV/heliosV5/medusa/
//     branch0 全家 primitives): 2026-11-21 起上游灰度收紧 x-medusa 的 packet/extract/embed
//     整体封装，手搓版逐字节不合规 → 12:42 遗嘱 v5 signed 段 15/15 口 200+0 全灭
//   · 预订单 reserve/v5BodyBatch (preload 批量 mixed): 同封装家族, 今日 0/75、0/6 全空
//   · 网页水闸 HGWater (720 双轨+360): 旧 1080 时代口粮, thl 换心后用户钦定退餐 (127 版遗产)
//
// 现役阵型: thlAttempt = web 1.3.5 正版三件套 (73932 族 + 单集接口 video_model/v1 + 明文 JSON),
//   x-khronos/x-helios/x-medusa 由 THLSign 产（JSCore 跑官方签名器 + sm3/md5/randomBytes Swift 反桥）;
//   五口轮射 v5Hosts, 首枪 reading.snssdk.com 实测 0.2s 命中 1080p (12:16 遗嘱 76/76)。
//   哑火时 HongguoLift.resolve 还有 svideo/cur/tab 五头系备炮(argus/ladon 验票体系, 另一族谱,
//   暂未同批殉职)，不在本文件管辖。

enum HGV5 {
    static let v5Hosts = [
        "https://reading.snssdk.com",
        "https://api5-normal-sinfonlineb.fqnovel.com",
        "https://api5-normal-sinfonlinea.fqnovel.com",
        // v1.10.138 军火版: jackotom 8.3 策略包 + TV 0.16.16 图纸新增两域 (桶旋转时多俩抽奖口)
        "https://api5-normal-sinfonlinec.fqnovel.com",
        "https://api3-normal-sinfonlinea.fqnovel.com",
    ]

    // ==== web 1.3.5 正门三件套 (73932 族 + 单集接口 + 明文 JSON + thl 签名) ====
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
        if empty > 0 { HGTrail.note("thlv5 全线空\(empty)口") }
        return nil
    }

    // 对外入口名不动 (HongguoLift.resolve 调用面零改动); 内部只剩换心主炮
    static func attempt(vid: String, dev: HongguoLift.Device) async -> HongguoLift.Lift? {
        await thlAttempt(vid: vid, dev: dev)
    }
}
