import Foundation
import AVFoundation
import UIKit

// 下载续命：一路 0 音量循环音轨 + 后台计时器断言
// —— 让盒子被抖音顶到后台/锁屏后仍能继续搬 m3u8 切片（侧载无审核顾虑，走混音不打扰对方声音）
@MainActor
final class BGKeepAlive {
    private var player: AVAudioPlayer?
    private var token: UIBackgroundTaskIdentifier = .invalid
    private var obs: NSObjectProtocol?

    func start() {
        guard player == nil else { return }
        if obs == nil {
            obs = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(), queue: .main) { note in
                let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    Task { @MainActor in
                        // 被抖音等抢走后 2 秒自我复活：重新激活会话并续播静音轨
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.player?.play()
                    }
                }
            }
        }
        arm()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWAV(seconds: 0.6))
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
        } catch { /* 拿不到音频权限也别影响下载 */ }
    }

    // 下载真正开跑时续期：重置后台时限 + 复活可能被抢走的静音轨
    func rearm() {
        if player == nil { start(); return }
        arm()
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
    }

    private func arm() {
        if token != .invalid {
            UIApplication.shared.endBackgroundTask(token)
            token = .invalid
        }
        token = UIApplication.shared.beginBackgroundTask(withName: "boxdl") { [weak self] in
            Task { @MainActor in self?.token = .invalid }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let obs { NotificationCenter.default.removeObserver(obs); self.obs = nil }
        try? AVAudioSession.sharedInstance().setActive(false)
        if token != .invalid {
            UIApplication.shared.endBackgroundTask(token)
            token = .invalid
        }
    }

    // 现场合成一段 8kHz 16bit 单声道纯静音 WAV（无需任何资源文件）
    nonisolated private static func silentWAV(seconds: Double) -> Data {
        let rate = 8000
        let frames = UInt32(max(1, Double(rate) * seconds))
        let dataBytes = frames * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(36 + dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        str("data"); u32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }
}
