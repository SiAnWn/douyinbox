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
        var stamp = Date().timeIntervalSince1970
    }
    typealias State = ContentState   // 协议要求嵌套名必须为 ContentState，别名保旧写法
}

enum BoxIsland {
    static func current() -> Activity<BoxActivity>? {
        Activity<BoxActivity>.activities.first
    }

    static func update(_ mutate: (inout BoxActivity.State) -> Void) {
        guard let act = current() else { return }
        var s = act.contentState
        mutate(&s)
        s.stamp = Date().timeIntervalSince1970
        Task { try? await act.update(using: s) }
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
        update {
            $0.phase = "parsing"; $0.note = ""
            $0.title = ""; $0.author = ""; $0.quality = ""; $0.link = ""
        }
        let clip = clipText() ?? ""
        guard let url = DouyinAPI.extractURL(clip) else {
            update { $0.phase = "fail"; $0.note = "剪贴板读不到链接（iOS后台限制），点胶囊体回App自动解析" }
            return
        }
        // 扩展进程的默认值与 App 独立：没填 Key 就用免费内置引擎，绝不硬抛 Key 错
        let eng = EngineStore.current
        if eng.isIfphp && KeyStore.value(for: eng).isEmpty {
            EngineStore.current = .web
        }
        do {
            let r = try await ParseRouter.parse(link: url)
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
            update {
                $0.phase = "fail"; $0.link = url
                $0.note = "解析失败（合集/特殊链接请回App）"
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
            $0.phase = "standby"; $0.note = ""
            $0.title = ""; $0.author = ""; $0.quality = ""; $0.link = ""
        }
        return .result()
    }
}
