import Foundation
import UIKit
import ActivityKit
import AppIntents

// MARK: - 灵动岛数据（App 与扩展共同编译）
struct BoxActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase = "standby"   // standby | parsing | parsed | fail
        var title = ""
        var author = ""
        var quality = ""
        var note = ""
        var link = ""
        var pct = 0            // 下载中：小胶囊直接显示百分比
        var stamp = Date().timeIntervalSince1970
    }
    typealias State = ContentState   // 协议要求嵌套名必须为 ContentState，别名保旧写法
}

enum BoxIsland {
    static func current() -> Activity<BoxActivity>? {
        Activity<BoxActivity>.activities.first
    }

    // 串行更新队列：ActivityKit 会丢弃时间戳倒序的更新，
    // 并发发送必然互相抢跑 → 卡进度。强制后发等先发落地。
    private static var pendingUpdate: Task<Void, Never>?

    static func update(_ mutate: (inout BoxActivity.ContentState) -> Void) {
        var act = current()
        if act == nil {                       // 岛被收回了？先复活再写，保证按钮永远有反馈
            ensureStandby()
            Thread.sleep(forTimeInterval: 0.35)
            act = current()
        }
        guard let act else { return }
        var s = act.contentState
        mutate(&s)
        s.stamp = Date().timeIntervalSince1970
        let prev = pendingUpdate
        pendingUpdate = Task {
            if let prev { _ = await prev.value }   // 排队：上一条送达后我再发
            try? await act.update(using: s)
        }
    }

    static func enabled() -> Bool {
        #if !ISLANDAPP
        return UserDefaults.standard.object(forKey: "islandOn") as? Bool ?? true
        #else
        return true
        #endif
    }

    static func ensureStandby() {
        guard enabled() else { endAll(); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if current() == nil {
            do {
                _ = try Activity<BoxActivity>.request(attributes: BoxActivity(),
                                                      contentState: BoxActivity.State(),
                                                      pushType: nil)
            } catch { /* 次数上限/未授权：静默 */ }
        }
    }

    static func endAll() {
        for a in Activity<BoxActivity>.activities {
            Task { try? await a.end(using: nil, dismissalPolicy: .immediate) }
        }
    }

    // 后台多通道读剪贴板：string 通道被 iOS 后台限制卡掉时，试 url/原始数据通道
    nonisolated static func clipText() -> String? {
        let pb = UIPasteboard.general
        if pb.hasStrings, let s = pb.string, !s.isEmpty { return s }
        if let u = pb.url { return u.absoluteString }
        let types = ["public.url", "public.utf8-plain-text", "public.plain-text",
                     "net.daringfireball.markdown", "public.text"]
        for t in types {
            if let d = pb.data(forPasteboardType: t),
               let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        }
        for it in pb.items {
            for (_, v) in it {
                var s: String?
                if let d = v as? Data { s = String(data: d, encoding: .utf8) }
                else if let ss = v as? String { s = ss }
                if let s = s, s.contains("http") { return s }
            }
        }
        return nil
    }

    // 实际解析：读剪贴板 → 解析 → 回写岛状态（全程不打开 App）
    @MainActor
    static func runParse() async {
        let clip = clipText() ?? ""
        guard let url = DouyinAPI.extractURL(clip) else {
            update { $0.phase = "fail"; $0.note = "后台读不到剪贴板(iOS限制)：请在抖音点 分享→抖音盒子" }
            return
        }
        await parseAndShow(url)
    }

    // 分享扩展直接送链接进来 → 解析上岛（不依赖剪贴板）
    @MainActor
    static func parseAndShow(_ url: String) async {
        ensureStandby()
        try? await Task.sleep(nanoseconds: 300_000_000)
        update {
            $0.phase = "parsing"; $0.note = ""; $0.pct = 0
            $0.title = ""; $0.author = ""; $0.quality = ""; $0.link = ""
        }
        // 扩展进程的默认值与 App 独立：没填 Key 就用免费内置引擎，绝不硬抛 Key 错
        let eng = EngineStore.current
        if eng.isIfphp && KeyStore.value(for: eng).isEmpty {
            EngineStore.current = .web
        }
        do {
            let r = try await withTimeout(14) { try await ParseRouter.parse(link: url) }
            let q = r.options.first
            update {
                $0.phase = "parsed"; $0.link = url
                $0.title = String(r.title.prefix(40))
                $0.author = String(r.author.prefix(16))
                $0.quality = q?.label ?? "?"
                var n = ""
                if let s = q?.sizeBytes, s > 0 { n = Naming.fmtSize(s) }
                if !r.images.isEmpty { n = "图文 \(r.images.count) 张" }
                $0.note = n
            }
        } catch {
            var timedOut = false
            if case GError.timeout = error { timedOut = true }
            update {
                $0.phase = "fail"; $0.link = url
                $0.note = timedOut ? "解析超时(14s)：再按一次或回App解析"
                                   : "解析失败（合集/特殊链接请回App）"
            }
        }
    }

    private static func withTimeout<T>(_ secs: Double,
                                       _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                throw GError.timeout
            }
            let v: T
            if let first = try await g.next() { v = first } else { throw GError.timeout }
            g.cancelAll()
            return v
        }
    }
}

// MARK: - 进度专用岛（第二个实时活动：多岛机型上以独立小圆气泡浮现，不被镜头遮挡）
struct BoxProgressActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var pct = 0            // 0-100
        var title = ""
        var done = false
        var failed = false
        var stamp = Date().timeIntervalSince1970
    }
    typealias State = ContentState
}

enum BoxProgress {
    static func current() -> Activity<BoxProgressActivity>? {
        Activity<BoxProgressActivity>.activities.first
    }

    private static func push(_ mutate: (inout BoxProgressActivity.ContentState) -> Void) {
        guard let act = current() else { return }
        var s = act.contentState
        mutate(&s)
        s.stamp = Date().timeIntervalSince1970
        Task { try? await act.update(using: s) }
    }

    @MainActor
    static func begin(_ title: String) {
        guard current() == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        var s = BoxProgressActivity.ContentState()
        s.title = String(title.prefix(28))
        do {
            _ = try Activity<BoxProgressActivity>.request(attributes: BoxProgressActivity(),
                                                          contentState: s, pushType: nil)
        } catch { /* 额度/未授权 */ }
    }

    static func updatePct(_ pct: Int) {
        push { $0.pct = max(0, min(100, pct)) }
    }

    @MainActor
    static func finish(ok: Bool) {
        push {
            $0.failed = !ok
            if ok { $0.pct = 100; $0.done = true }
        }
        guard let act = current() else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if let a = Activity<BoxProgressActivity>.activities.first(where: { $0.id == act.id }) {
                try? await a.end(dismissalPolicy: .immediate)
            }
        }
    }
}

// MARK: - App Intents

// 一键：点岛按钮 → 不打开 App，直接后台解析
// （Xcode26/iOS26：岛上按钮必须 LiveActivityIntent，App 进程后台执行不弹界面）
struct ParseClipIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "盒子：解析剪贴板"
    static var openAppWhenRunning = false    // 关键：不打开 App，后台进程直接干活
    func perform() async throws -> some IntentResult {
        await BoxIsland.runParse()
        return .result()
    }
}

// 已解析 → 开始下载（App 进程被唤醒，直接走完整下载管线，界面不用露面）
struct IslandDownloadIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "盒子：开始下载"
    static var openAppWhenRunning = false    // 后台唤醒 App 进程开下，界面不出场
    @Parameter(title: "链接") var link: String?
    init() {}
    init(link: String) { self.link = link }
    func perform() async throws -> some IntentResult {
        #if !ISLANDAPP
        let l = link ?? BoxIsland.current()?.contentState.link ?? ""
        Task { @MainActor in
            AppState.shared.islandDownload(l)
        }
        #endif
        BoxIsland.update { $0.note = "已回App，开始下载…" }
        return .result()
    }
}

// 恢复待命
struct IslandStandbyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "盒子：重新待命"
    static var openAppWhenRunning = false
    func perform() async throws -> some IntentResult {
        BoxIsland.update {
            $0.phase = "standby"; $0.note = ""; $0.pct = 0
            $0.title = ""; $0.author = ""; $0.quality = ""; $0.link = ""
        }
        return .result()
    }
}
