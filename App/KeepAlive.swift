import AVFoundation

// MARK: - 下载续命符（v1.10.16）
// 盒子管线是进程内 Task 链, App 一进后台就被 iOS 挂起(下载冻住, 切回才解冻——用户实锤)。
// 下载全程播一段 2 秒静音循环(mixWithOthers+音量0, 听不见也不抢别人音频),
// 音频会话活跃=进程不被挂起, 锁屏照下。批任务结束即交还, 不恋战省电。

final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVPlayer?
    private var endObs: NSObjectProtocol?

    func start() {
        guard player == nil,
              let u = Bundle.main.url(forResource: "silent", withExtension: "wav") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                        options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: u)
        let pl = AVPlayer(playerItem: item)
        pl.setVolume(0, atTime: nil)
        player = pl
        pl.play()
        // 本地小文件循环: 播完归零再踢(自滤 object 只认自家 item, lesson v1.10.13)
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak pl] _ in
                pl?.seek(to: .zero)
                pl?.play()
            }
    }

    func stop() {
        guard player != nil else { return }
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        player?.pause()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
