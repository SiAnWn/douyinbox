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
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: items.isEmpty)) { _ in
            Canvas { g, size in
                guard !items.isEmpty else { return }
                let nowMs = max(0, CMTimeGetSeconds(pc.player.currentTime()) * 1000.0)
                let rowH: CGFloat = 24
                let lanes = max(4, Int((size.height * 0.30 - 40) / rowH))
                let speed = 150.0            // px/s 匀速飘
                let topPad: CGFloat = 76     // 躲灵动岛
                g.addFilter(.shadow(color: .black.opacity(0.75), radius: 2))
                var drawn = 0
                for (i, it) in items.enumerated() {
                    if it.t > Int(nowMs) + 300 { break }      // items 按时间排序, 后面都更晚
                    let age = nowMs - Double(it.t)
                    if age < 0 { continue }
                    let w = CGFloat(it.x.count) * 14 + 12
                    let x = Double(size.width) - age / 1000.0 * speed
                    if x < -Double(w) { continue }
                    var ln = (i * 7 + i / 3) % lanes
                    if ln < 0 { ln += lanes }
                    let y = topPad + CGFloat(ln) * rowH
                    g.draw(Text(it.x).font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white),
                           at: CGPoint(x: x, y: y), anchor: .leading)
                    drawn += 1
                    if drawn >= 48 { break }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
