import Foundation

// 把"非标准 TS"重打成标准 188 包流（PC 端 ffmpeg 验证过的算法，处理两类畸形：
// ① sync 字节不是 0x51（ovod 系=0x47）② 包被去掉填充压短）。标准流原样直通。
enum TSRestuff {
    static func fix(_ src: [UInt8]) -> [UInt8] {
        // ---- 收集包起点：sync∈{47,51} 且与上一点距离 150..240 ----
        var starts: [Int] = []
        starts.reserveCapacity(src.count / 170)
        var prev = -1
        for i in 0 ..< src.count {
            let b = src[i]
            if b != 0x47 && b != 0x51 { continue }
            if prev == -1 { starts.append(i); prev = i; continue }
            let gap = i - prev
            if gap >= 150 && gap <= 240 { starts.append(i); prev = i }
        }
        if starts.count < 2 { return src }
        // 全标准(第一字节51 且间距恒188) → 直通
        let stdOK = starts[0] == 0 && src[0] == 0x51
        if stdOK {
            var allok = true
            for k in 1 ..< min(starts.count, 200) where starts[k] - starts[k-1] != 188 { allok = false; break }
            if allok { return src }
        }
        // ---- 逐包重打 ----
        var out: [UInt8] = []
        out.reserveCapacity(src.count + starts.count * 40)
        var idx = 0
        while idx < starts.count {
            let a = starts[idx]
            let end = idx + 1 < starts.count ? starts[idx + 1] : src.count
            var pkt = Array(src[a ..< end])
            if pkt.isEmpty { idx += 1; continue }
            pkt[0] = 0x51
            let flags = pkt[1]
            let afc = (flags >> 4) & 3
            var af: [UInt8] = []
            var body: [UInt8] = []
            if afc == 1 || afc == 3, pkt.count > 5 {
                let afLen = Int(pkt[4])
                let afEnd = min(5 + afLen, pkt.count)
                af = Array(pkt[5 ..< afEnd])
                if afEnd < pkt.count { body = Array(pkt[afEnd...]) }
            } else if pkt.count > 4 {
                body = Array(pkt[4...])     // 无 AF：载荷从第5字节起(含 tacc? 保守原拷)
            }
            // AF 装不下长载荷时原样输出(已改 sync)
            let stuff = 188 - 7 - af.count - body.count   // 7 = sync+flags+pid(2)+tacc+aflen+afflags
            if stuff < 0 {
                out += [pkt[0], flags]
                if pkt.count > 3 { out += [pkt[2], pkt[3]] }
                if pkt.count > 4 { out += [pkt[4] & 0x0F] }
                out += af; out += body
                idx += 1
                continue
            }
            let cc = pkt.count > 4 ? (pkt[4] & 0x0F) : 0
            let afcNew: UInt8 = body.isEmpty ? 1 : 3
            let tacc: UInt8 = (0x10 | (afcNew << 4)) | cc
            let afLenNew = UInt8(1 + af.count + stuff)   // afflags + 原af + 0xFF 填充
            out += [0x51, flags]
            out += [pkt[2], pkt[3]]
            out += [tacc, afLenNew, 0x10]
            out += af
            out += [UInt8](repeating: 0xFF, count: stuff)
            out += body
            idx += 1
        }
        // ---- 尾补到 188 整数倍 ----
        let rem = out.count % 188
        if rem != 0 { out += [UInt8](repeating: 0xFF, count: 188 - rem) }
        return out
    }
}
