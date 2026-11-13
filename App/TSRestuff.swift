import Foundation

// "怪包 TS"修复（ovod / 91tanhua / hwzcfz 实测同一族）：
// 分片本来就是标准 188 字节网格 + 0x47 同步，唯一畸形是 AFC 标志位=0(保留值)，
// ffmpeg 宽容能读、AVPlayer 严格则花屏/无声。修复=逐包 in-place：
//   · 同步字节非 0x47 → 归一为 0x47
//   · AFC==0 → 改写为 2(载荷从第4字节起，位置不变)
//   · 其他字段(含 PUSI/PID/CC/AF)一律不动
// 网格不完美(变长包)时退回逐包重建；实在不像 TS 就原样直通。
// PC 端 ffmpeg -f mpegts 三站验证：h264+aac、时长精确 ✓
enum TSRestuff {
    static func fix(_ src: [UInt8]) -> [UInt8] {
        let n = src.count
        guard n >= 188 else { return src }

        // ---- 快路径：完美 188 网格 → 原位最小修复 ----
        if n % 188 == 0 {
            var gridOK = true
            var i = 0
            while i < n {
                let s = src[i]
                if s != 0x47 && s != 0x51 { gridOK = false; break }
                i += 188
            }
            if gridOK {
                var d = src
                i = 0
                while i < n {
                    if d[i] != 0x47 { d[i] = 0x47 }
                    let f = d[i + 1]
                    if ((f >> 3) & 3) == 0 { d[i + 1] = (f & 0xE7) | 0x10 }
                    i += 188
                }
                return d
            }
        }

        // ---- 慢路径：变长包 → 收集包起点逐包重建 ----
        var stl: [Int] = []
        stl.reserveCapacity(n / 170)
        var prev = -1
        for j in 0 ..< n {
            let b = src[j]
            if b != 0x47 && b != 0x51 { continue }
            if prev == -1 { stl.append(j); prev = j; continue }
            let gap = j - prev
            if gap >= 150 && gap <= 240 { stl.append(j); prev = j }
        }
        if stl.count < 4 { return src }              // 不像 TS：原样(交给播放器赌一把)
        var out: [UInt8] = []
        out.reserveCapacity(n + stl.count * 8)
        if stl[0] > 0 && stl[0] < 32 { }             // 前导丢弃由下面统一处理
        for idx in 0 ..< stl.count {
            let a = stl[idx]
            let end = idx + 1 < stl.count ? stl[idx + 1] : n
            var pkt = Array(src[a ..< end])
            if pkt.count < 5 { continue }
            pkt[0] = 0x47                            // 标准同步字节
            let flags = pkt[1]
            let afc = (flags >> 3) & 3               // 正确位域(bits 4-3)
            let cc = pkt[3] & 0x0F                   // CC 在第4字节低 4 位
            var af: [UInt8] = []
            var body: [UInt8] = []
            if afc == 3 {
                let afl = Int(pkt[4])
                let afEnd = min(5 + afl, pkt.count)
                af = Array(pkt[5 ..< afEnd])
                if afEnd < pkt.count { body = Array(pkt[afEnd...]) }
            } else if afc == 1 {
                let afl = Int(pkt[4])
                af = Array(pkt[5 ..< min(5 + afl, pkt.count)])
            } else {
                body = Array(pkt[4...])              // afc 0/2: 载荷从第4字节
            }
            var fl = flags
            if body.count >= 184 {
                // 满载荷：AFC=2，4 字节头，零改动除同步(=网格路径等价)
                fl = (fl & 0xE7) | 0x10
                out += [0x47, fl, pkt[2], pkt[3]]
                out += Array(body[0 ..< 184])
            } else if body.isEmpty && !af.isEmpty {
                // 纯适配字段包：AFC=1，AF 原样 + 0xFF 补满
                fl = (fl & 0xE7) | 0x08
                if af.count > 178 { af = Array(af[0 ..< 178]) }
                let need = 183 - af.count
                out += [0x47, fl, pkt[2], pkt[3], UInt8(af.count + need)]
                out += af
                out += [UInt8](repeating: 0xFF, count: need)
            } else {
                // 载荷包(载荷<184)：AFC=3，AF 承载补位 → 恒 188
                fl = (fl & 0xE7) | 0x18
                let afLen = 183 - body.count
                if afLen == 0 {
                    out += [0x47, fl, pkt[2], pkt[3], 0x00]
                } else {
                    out += [0x47, fl, pkt[2], pkt[3], UInt8(afLen), 0x10]
                    out += [UInt8](repeating: 0xFF, count: afLen - 1)
                }
                out += body
            }
        }
        let rem = out.count % 188
        if rem != 0 { out += [UInt8](repeating: 0xFF, count: 188 - rem) }
        return out
    }
}
