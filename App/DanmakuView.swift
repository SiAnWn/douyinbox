import SwiftUI
import AVFoundation

// MARK: - 离线弹幕（v1.10.14）: 领档案时已把精选弹幕全量落盘(弹幕.json),
// 播放时按视频时间轴飘屏, 全程不联网。车道=确定性哈希错峰, 单屏上限防刷屏。

struct DMItem: Hashable {
    let t: Int      // 出现时间, 毫秒
    let x: String   // 文本
}

struct DanmakuLayer: View {
    let pc: PlayerController
    let items: [DMItem]
    // 引擎心跳探针: 简介弹层里可见
    static var ticks = 0
    static var lastVisible = 0
    static var lastNow = -999.0     // 上次读到的视频秒(-999=还没跑, NaN 场景会显 -9)
    // 帧源=Timer 发布器(最原始可靠): TimelineView(.animation) 实测在坊页内被 SwiftUI 判休眠
    private let beat = Timer.publish(every: 1.0 / 24.0, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        Canvas { g, size in
            DanmakuLayer.ticks &+= 1
            guard !items.isEmpty else { DanmakuLayer.lastVisible = 0; return }
            let t0 = CMTimeGetSeconds(pc.player.currentTime()) * 1000.0
            guard t0.isFinite else {
                DanmakuLayer.lastVisible = -9; DanmakuLayer.lastNow = -9
                return
            }
            let nowMs = max(0, t0)
            DanmakuLayer.lastNow = nowMs / 1000.0
            let rowH: CGFloat = 24
            let lanes = max(4, Int((size.height * 0.30 - 40) / rowH))
            let speed = 150.0            // px/s 匀速飘
            let topPad: CGFloat = 76     // 躲灵动岛
            g.addFilter(.shadow(color: .black.opacity(0.75), radius: 2))
            var drawn = 0
            for (i, it) in items.enumerated() {
                if Double(it.t) > nowMs + 300 { break }    // items 按时间排序, 后面都更晚
                let age = nowMs - Double(it.t)
                if age < 0 { continue }
                let w = CGFloat(it.x.count) * 14 + 12
                let x = Double(size.width) - age / 1000.0 * speed
                if x < -w { continue }
                var ln = (i * 7 + i / 3) % lanes
                if ln < 0 { ln += lanes }
                let y = topPad + CGFloat(ln) * rowH
                g.draw(Text(it.x).font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white),
                       at: CGPoint(x: x, y: y), anchor: .leading)
                drawn += 1
                if drawn >= 48 { break }
            }
            DanmakuLayer.lastVisible = drawn
        }
        .onReceive(beat) { now = $0 }     // 24fps 心跳踢 body 重绘
        .allowsHitTesting(false)
    }
}
