import Foundation
import AVFoundation

// ============ 智能 HLS 下载分流 ============
// 🌐 嗅探来源(未知站) → 先试 iOS 原生 HLS(AVAssetDownloadURLSession，Apple 的 TS 解包器
//    能啃各家畸形流，产物可播 .mov)；失败退回自写管线(.ts)。
// 站点规则/直链粘贴(已知标准流) → 自写管线先跑；失败再退原生。
enum HLSSmart {
    // baseName 不含扩展名；返回实际保存的相对路径
    static func download(baseName: String, m3u8Str: String, tok: HLSToken, preferApple: Bool,
                         progress: @escaping @Sendable (Double, Double) -> Void) async throws -> String {
        guard let m3u8 = URL(string: m3u8Str) else { throw GError.noStream }
        let refer = tok.referer.isEmpty ? m3u8Str : tok.referer
        var firstError: Error?
        if preferApple {
            do { return try await AppleHLS.shared.download(m3u8: m3u8, referer: refer,
                cookie: tok.cookie, destRel: baseName + ".mov", progress: progress) }
            catch { firstError = error }
            do { let rel = try await HLS.download(m3u8URLString: m3u8Str, tok: tok,
                destRel: baseName + ".ts", progress: progress)
                return rel } catch { throw firstError ?? error }
        } else {
            do { return try await HLS.download(m3u8URLString: m3u8Str, tok: tok,
                destRel: baseName + ".ts", progress: progress) }
            catch { firstError = error }
            do { return try await AppleHLS.shared.download(m3u8: m3u8, referer: refer,
                cookie: tok.cookie, destRel: baseName + ".mov", progress: progress) }
            catch { throw firstError ?? error }
        }
    }
}

// ============ iOS 原生 HLS 下载会话 ============
final class AppleHLS: NSObject, AVAssetDownloadDelegate {
    static let shared = AppleHLS()
    private struct Pending {
        let destRel: String
        let cont: CheckedContinuation<String, Error>
        let progress: @Sendable (Double, Double) -> Void
        var lastBytes = 0
        var lastTime = Date()
        var speed = 0.0
        var finished = false
    }
    private var table: [Int: Pending] = [:]
    private let lock = NSLock()
    private var keepLoaders: [Int: HLSResLoader] = [:]
    private lazy var session: AVAssetDownloadURLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.sian.douyinbox.hlsdl")
        cfg.httpAdditionalHeaders = ["User-Agent": DouyinAPI.ua]
        return AVAssetDownloadURLSession(configuration: cfg, assetDownloadDelegate: self, delegateQueue: nil)
    }()

    func download(m3u8: URL, referer: String, cookie: String, destRel: String,
                  progress: @escaping @Sendable (Double, Double) -> Void) async throws -> String {
        let asset = AVURLAsset(url: m3u8, options: ["AVURLAssetHTTPHeaderFieldsKey":
            ["Referer": referer, "Cookie": cookie]])
        let loader = HLSResLoader(referer: referer, cookie: cookie)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "dsh.hlsrl"))
        guard let task = session.makeAssetDownloadTask(asset: asset,
            assetTitle: destRel, assetMetadata: nil,
            acceptedManualTrackSelection: false) else {
            throw GError.failed("系统未能创建 HLS 下载任务")
        }
        let tid = task.taskIdentifier
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            lock.lock()
            table[tid] = Pending(destRel: destRel, cont: c, progress: progress)
            keepLoaders[tid] = loader
            lock.unlock()
            task.resume()
            Task { @MainActor [weak task] in
                while true {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let t = task else { break }
                    let done = AppleHLS.shared.tick(tid, t)
                    if done { break }
                }
            }
        }
    }

    @MainActor
    fileprivate func tick(_ tid: Int, _ t: AVAssetDownloadTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var p = table[tid], !p.finished else { return true }
        let now = Date()
        let dt = max(now.timeIntervalSince(p.lastTime), 0.001)
        let recv = Int(t.countOfBytesReceived)
        let delta = max(recv - p.lastBytes, 0)
        let sps = Double(delta) / dt
        p.speed = p.speed == 0 ? sps : p.speed * 0.7 + sps * 0.3
        p.lastBytes = recv
        p.lastTime = now
        table[tid] = p
        p.progress(Double(t.progress?.fractionCompleted ?? 0), p.speed)
        return false
    }

    // MARK: 完成/失败
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let tid = assetDownloadTask.taskIdentifier
        lock.lock(); let p = table[tid]; lock.unlock()
        guard let p = p, !p.finished else { return }
        var rel = p.destRel
        if !rel.lowercased().hasSuffix(".mov") { rel += ".mov" }
        let ok = Self.extractPackage(at: location, rel: rel)
        lock.lock(); if var q = table[tid] { q.finished = true; table[tid] = q }; lock.unlock()
        keepLoaders.removeValue(forKey: tid)
        if ok { p.cont.resume(returning: rel) }
        else { p.cont.resume(throwing: GError.failed("原生下载完成但保存失败")) }
    }

    private static func extractPackage(at pkg: URL, rel: String) -> Bool {
        let fm = FileManager.default
        let dest = SavePaths.docs.appendingPathComponent(rel)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var candidates: [URL] = [pkg.appendingPathComponent("Complete.mov")]
        if let en = try? fm.enumerator(at: pkg, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension.lowercased() == "mov" { candidates.append(u) }
        }
        defer { try? fm.removeItem(at: pkg) }
        for c in candidates where fm.fileExists(atPath: c.path) {
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: c, to: dest)) != nil { return true }
        }
        return false
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        lock.lock(); let p = table[tid]; lock.unlock()
        if let e = error, let p = p, !p.finished {
            lock.lock(); if var q = table[tid] { q.finished = true; table[tid] = q }; lock.unlock()
            keepLoaders.removeValue(forKey: tid)
            p.cont.resume(throwing: GError.failed("原生HLS失败: \(e.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeAvailable: CMTime,
                    timeRemaining: CMTime) {
        _ = assetDownloadTask; _ = timeRange; _ = totalTimeAvailable; _ = timeRemaining
    }
}

// Apple 发出的清单/分片/密钥请求 → 补 Referer/Cookie 后我们代发
final class HLSResLoader: NSObject, AVAssetResourceLoaderDelegate {
    let referer: String
    let cookie: String
    init(referer: String, cookie: String) { self.referer = referer; self.cookie = cookie }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request?.url else { return false }
        var req = URLRequest(url: url)
        req.setValue(DouyinAPI.ua, forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let task = URLSession.shared.dataTask(with: req) { data, _, err in
            if let d = data, !d.isEmpty {
                loadingRequest.contentInformationRequest?.contentType =
                    Self.mime(for: url.pathExtension.lowercased())
                loadingRequest.dataResponse?.appendData(d)
                loadingRequest.finishLoading()
            } else {
                loadingRequest.finishLoading(with: err ?? GError.http(404))
            }
        }
        task.resume()
        return true
    }

    static func mime(for ext: String) -> String {
        switch ext {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "key": return "application/octet-stream"
        default: return "video/mp4"
        }
    }
}
