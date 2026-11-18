import SwiftUI
import AVFoundation
import UIKit

// MARK: - 离线弹幕引擎 v2（v1.10.21）：CoreAnimation 驱动
// Canvas 主线程重绘(先 TimelineView 后 Timer)真机始终卡顿; 改红果/DanmakuFlame 正解:
// 每条弹幕一个 UILabel, 入场一次, 位移交给 CA 线性动画(GPU 跑), 主线程只在出现时刻点名。
// 暂停=layer.speed=0 与播放器 rate 帧同步原地冻住; 换集=items 变更全清重开。

struct DMItem: Hashable {
    let t: Int      // 出现时间, 毫秒
    let x: String   // 文本
}

final class DanmakuEngineView: UIView {
    weak var player: AVPlayer?
    var items: [DMItem] = [] {
        didSet { if items != oldValue { reload() } }
    }
    private var idx = 0
    private var lastT: Double = -1
    private var link: CADisplayLink?

    private let laneN = 7
    private let rowH: CGFloat = 27
    private let topPad: CGFloat = 80      // 躲灵动岛
    private let speed: CGFloat = 150      // px/s 匀速飘
    private var laneFree: [Double] = Array(repeating: 0, count: 7)   // 各道占用到几毫秒(占用制防叠车)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startLink() } else { stopLink() }
    }

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    private func stopLink() { link?.invalidate(); link = nil }

    private func reload() {
        subviews.forEach { $0.removeFromSuperview() }
        idx = 0
        lastT = -1
        laneFree = Array(repeating: 0, count: laneN)
    }

    private func spawn(_ it: DMItem, slot: Int, now: Double) {
        let lb = UILabel()
        // 长弹幕截断: 一屏 30 字封顶, 防超宽条占轨太久引发连环叠
        let text = it.x.count > 30 ? String(it.x.prefix(29)) + "…" : it.x
        lb.text = text
        lb.font = .systemFont(ofSize: 13, weight: .medium)
        lb.textColor = .white
        lb.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        lb.layer.cornerRadius = 11
        lb.layer.masksToBounds = true
        lb.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: lb.font as Any]
        let tw = (text as NSString).size(withAttributes: attrs).width
        let w = ceil(tw) + 20
        let travel = Double(bounds.width + w + 80) / Double(speed) * 1000.0
        // 占用制: 找最早空闲的道; 全忙则挑最快恢复的道排队(右缘等着, delay 后出发)
        var lane = 0
        var delay = 0.0
        var best = -1
        for i in 0..<laneN where laneFree[i] <= now { best = i; break }
        if best < 0 {
            best = 0
            for i in 1..<laneN where laneFree[i] < laneFree[best] { best = i }
            delay = max(0, (laneFree[best] - now) / 1000.0)
        }
        lane = best
        laneFree[lane] = now + delay * 1000.0 + travel
        let y = topPad + CGFloat(lane) * rowH + CGFloat((slot * 53) % 7)   // 微错峰防齐边
        lb.frame = CGRect(x: bounds.width, y: y, width: w, height: 22)
        addSubview(lb)
        UIView.animate(withDuration: travel / 1000.0, delay: delay,
                       options: [.curveLinear, .allowUserInteraction, .beginFromCurrentState]) {
            lb.frame = CGRect(x: -w - 80, y: y, width: w, height: 22)
        } completion: { _ in
            lb.removeFromSuperview()
        }
    }

    @objc private func tick() {
        DanmakuLayer.ticks &+= 1
        guard let pl = player, !items.isEmpty else {
            DanmakuLayer.lastVisible = 0
            return
        }
        let t0 = CMTimeGetSeconds(pl.currentTime()) * 1000.0
        guard t0.isFinite else { return }
        let now = max(0, t0)
        DanmakuLayer.lastNow = now / 1000.0
        layer.speed = pl.rate == 0 ? 0 : 1        // 暂停=所有飘动原地冻, 恢复=原地续飘
        if now < lastT - 1200 { rewind(to: now) }                 // 回跳 seek
        else if now > lastT + 3000 { idx = lower(now) }           // 前跳直接到位
        lastT = now
        while idx < items.count, Double(items[idx].t) <= now + 150 {
            if now - Double(items[idx].t) < 2000 { spawn(items[idx], slot: idx, now: now) }  // 补档积压不补飘
            idx += 1
        }
        DanmakuLayer.lastVisible = subviews.count
    }

    private func lower(_ now: Double) -> Int {
        var lo = 0
        var hi = items.count
        while lo < hi {
            let m = (lo + hi) / 2
            if Double(items[m].t) < now - 1500 { lo = m + 1 } else { hi = m }
        }
        return lo
    }
    private func rewind(to now: Double) {
        subviews.forEach { $0.layer.removeAllAnimations(); $0.removeFromSuperview() }
        laneFree = Array(repeating: now, count: laneN)   // seek 后以当前时刻重新占轨
        idx = lower(now)
    }
}

struct DanmakuLayer: View {
    let pc: PlayerController
    let items: [DMItem]
    // 引擎探针(简介弹层读数): 帧=CADisplayLink tick; 在屏=现役 label 数
    static var ticks = 0
    static var lastVisible = 0
    static var lastNow = -999.0

    var body: some View {
        Host(pc: pc, items: items)
            .allowsHitTesting(false)
    }

    private struct Host: UIViewRepresentable {
        let pc: PlayerController
        let items: [DMItem]
        func makeUIView(context: Context) -> DanmakuEngineView {
            let v = DanmakuEngineView()
            v.player = pc.player
            v.items = items
            return v
        }
        func updateUIView(_ v: DanmakuEngineView, context: Context) {
            v.player = pc.player
            if v.items != items { v.items = items }   // 换集全清重开
        }
    }
}
