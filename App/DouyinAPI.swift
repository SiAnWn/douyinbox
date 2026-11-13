import Foundation
import UIKit

struct QualityOption {
    let label: String
    let url: URL
    let width: Int
    let height: Int
    let sizeBytes: Int
    let isOriginal: Bool
    var isHLS = false          // true=清单流(走 HLS 管线下载，url 仅作占位/真实 m3u8)
}

struct ParseResult: Identifiable {
    let id = UUID()
    let videoID: String
    let title: String
    let author: String
    let options: [QualityOption]
}

enum GError: LocalizedError {
    case noURL, failed(String), noData, noStream, http(Int), timeout
    var errorDescription: String? {
        switch self {
        case .noURL: return "链接里没找到网址"
        case .failed(let m): return m
        case .noData: return "接口没返回数据"
        case .noStream: return "没有可下载的清晰度"
        case .http(let c): return "HTTP \(c)"
        case .timeout: return "解析超时（抖音可能弹了登录/验证，可稍后重试或换引擎）"
        }
    }
}

enum DouyinAPI {
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func extractURL(_ text: String) -> String? { RegexHelper.firstFullURL(text) }

    // 按下载域名自动带 Referer（抖音 CDN 要 douyin；B站直链要 bilibili，否则 403）
    static func referer(for url: URL) -> String {
        let h = url.host?.lowercased() ?? ""
        if h.contains("bilivideo") || h.contains("bilibili") { return "https://www.bilibili.com/" }
        if h.contains("kuaishou") || h.contains("gifshow") || h.contains("klivo") { return "https://www.kuaishou.com/" }
        return "https://www.douyin.com/"
    }

    static func download(_ url: URL, referer: String = "",
                         progress: @escaping @Sendable (Double, Double) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        return try await d.start(url, referer: referer.isEmpty ? referer(for: url) : referer, ua: ua)
    }
}

enum RegexHelper {
    static func firstFullURL(_ s: String) -> String? {
        if let r = range(s, pattern: "https?://[^\\s，,、]+") { return String(s[r]) }
        return nil
    }
    static func range(_ s: String, pattern: String) -> Range<String.Index>? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: ns), let r = Range(m.range, in: s) else { return nil }
        return r
    }
    static func firstGroup(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: ns) else { return nil }
        for g in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: g), in: s) { return String(s[r]) }
        }
        return nil
    }
}

func strOf(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func intOf(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

// MARK: - 存储目录：根(视频库) / 短剧/<名> / 私密/<名>
enum SavePaths {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func root(_ base: String) -> URL {          // base = "短剧" / "私密"
        let d = docs.appendingPathComponent(base, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func seriesDir(base: String, name: String) -> URL {   // 合集/创作者文件夹
        let d = root(base).appendingPathComponent(Naming.sanitize(name), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func exists(rel: String) -> Bool {
        FileManager.default.fileExists(atPath: docs.appendingPathComponent(rel).path)
    }
    @discardableResult
    static func write(_ file: URL, rel: String) -> Bool {   // rel 如 "短剧/王某/01_x.mp4" 或 "x.mp4"(库)
        let dest = docs.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        return (try? FileManager.default.copyItem(at: file, to: dest)) != nil
    }
}

enum DownloadStore {
    private static let key = "downloadedMap"
    static func map() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
    static func set(_ k: String, _ rel: String) {
        var m = map(); m[k] = rel; UserDefaults.standard.set(m, forKey: key)
    }
}

// MARK: - 命名/格式工具
enum Naming {
    static let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
    static func sanitize(_ s: String) -> String {
        var t = s.components(separatedBy: illegal).joined(separator: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func fileName(_ author: String, _ title: String, _ opt: QualityOption) -> String {
        let a = sanitize(author), c = sanitize(title)
        var base = [a, c].filter { !$0.isEmpty }.joined(separator: " ")
        let tag = sanitize(opt.label).replacingOccurrences(of: "（最高画质）", with: "")
        if !tag.isEmpty { base += "_" + tag }
        if base.count > 60 { base = String(base.prefix(60)) }
        if base.isEmpty { base = "douyin_\(opt.width)x\(opt.height)_\(Int(Date().timeIntervalSince1970))" }
        return base + ".mp4"
    }
    static func fmtSpeed(_ bps: Double) -> String {
        if bps <= 0 { return "计算中…" }
        if bps >= 1048576 { return String(format: "%.1f MB/s", bps / 1048576.0) }
        return String(format: "%.0f KB/s", bps / 1024.0)
    }
    static func fmtSize(_ b: Int) -> String {
        b > 0 ? String(format: "%.1f MB", Double(b) / 1048576.0) : "大小未知"
    }
    static func epName(num: Int, title: String) -> String {
        let c = sanitize(title)
        var base = String(format: "%02d_", num) + c
        if base.count > 64 { base = String(base.prefix(64)) }
        return base + ".mp4"
    }
}

// MARK: - 下载代理（进度/速度回调）
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let progress: @Sendable (Double, Double) -> Void
    private var cont: CheckedContinuation<URL, Error>?
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    private var smooth: Double = 0

    init(progress: @escaping @Sendable (Double, Double) -> Void) { self.progress = progress }

    func start(_ url: URL, referer: String, ua: String) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: req)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            self.cont = c; self.lastTime = Date(); task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date(); let dt = now.timeIntervalSince(lastTime)
        let frac = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        if dt > 0 { let inst = Double(totalBytesWritten - lastBytes) / dt; smooth = smooth == 0 ? inst : smooth * 0.8 + inst * 0.2 }
        lastBytes = totalBytesWritten; lastTime = now
        progress(frac, smooth)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dy_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { cont?.resume(returning: dest) }
        else { cont?.resume(throwing: GError.failed("保存临时文件失败")) }
        cont = nil; session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error, cont != nil { cont?.resume(throwing: e); cont = nil; session.finishTasksAndInvalidate() }
    }
}
