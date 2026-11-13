import Foundation
import AVFoundation
import UIKit
import UniformTypeIdentifiers

struct VideoItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let modDate: Date
    let size: Int
    static func == (l: VideoItem, r: VideoItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct Series: Identifiable, Hashable {
    let id: String      // 文件夹路径
    let name: String    // 文件夹名（剧名/合集名）
    let count: Int
    let url: URL
    let cover: URL?
}

enum Library {
    static func root() -> URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    // 子文件夹（短剧 / 私密），不存在则创建
    static func sub(_ name: String) -> URL {
        let d = root().appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static let keys: [URLResourceKey] = [
        .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .contentTypeKey
    ]

    static func scan(in dir: URL) -> [VideoItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var items: [VideoItem] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let ok = v.contentType.map { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                ?? ["mp4", "mov", "m4v", "ts", "tsv", "video"].contains(u.pathExtension.lowercased())
            guard ok else { continue }
            items.append(VideoItem(id: u.path, url: u,
                                   title: u.deletingPathExtension().lastPathComponent,
                                   modDate: v.contentModificationDate ?? .distantPast,
                                   size: v.fileSize ?? 0))
        }
        return items
    }

    static func scanRootByDate() -> [VideoItem] {
        scan(in: root()).sorted { $0.modDate > $1.modDate }
    }

    // 按文件名中的数字升序（无数字排最后）
    static func scanNumeric(_ dir: URL) -> [VideoItem] {
        scan(in: dir).sorted { a, b in
            let na = numKey(a.title), nb = numKey(b.title)
            if na != nb { return na < nb }
            return a.title < b.title
        }
    }

    static func numKey(_ s: String) -> Int {
        if let r = s.range(of: "[0-9]+", options: .regularExpression) {
            return Int(s[r]) ?? Int.max
        }
        return Int.max
    }

    // 列出某根目录下的子文件夹（每个=一部短剧/一个合集）
    static func series(in root: URL) -> [Series] {
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var out: [Series] = []
        for d in subs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let vids = scan(in: d)
            guard !vids.isEmpty else { continue }
            let cover = vids.max(by: { $0.modDate < $1.modDate })?.url
            out.append(Series(id: d.path, name: d.lastPathComponent, count: vids.count, url: d, cover: cover))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // 读取某文件夹里的视频；numeric=true 按数字升序（短剧），false 按时间（私密）
    static func videos(in dir: URL, numeric: Bool) -> [VideoItem] {
        let v = scan(in: dir)
        if numeric {
            return v.sorted { a, b in
                let na = numKey(a.title), nb = numKey(b.title)
                if na != nb { return na < nb }
                return a.title < b.title
            }
        }
        return v.sorted { $0.modDate > $1.modDate }
    }
}

actor ThumbCache {
    static let shared = ThumbCache()
    private var mem = NSCache<NSString, UIImage>()

    func image(_ url: URL) async -> UIImage? {
        let k = url.path as NSString
        if let c = mem.object(forKey: k) { return c }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        if let res = try? await gen.image(at: .zero) {
            let img = UIImage(cgImage: res.image)
            mem.setObject(img, forKey: k)
            return img
        }
        return nil
    }
}

// MARK: - 应用内标签（key=文件路径；改名自动跟随；跨引擎位置无关仅库根）
extension VideoItem {
    static func fromURLString(_ s: String, kind: String) -> VideoItem? {
        guard let u = URL(string: s) else { return nil }
        return VideoItem(id: "web_\(s)", url: u,
                         title: u.deletingPathExtension().lastPathComponent,
                         modDate: Date(), size: 0)
    }
}

enum TagStore {
    private static let key = "videoTags"
    static let suggestions = ["跳舞", "搞笑", "知识", "音乐", "游戏", "生活", "影视", "其他"]

    private static func dict() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }
    private static func save(_ d: [String: [String]]) { UserDefaults.standard.set(d, forKey: key) }

    static func tags(_ id: String) -> [String] { dict()[id] ?? [] }

    static func toggle(_ id: String, _ tag: String) {
        var d = dict(); var t = d[id] ?? []
        if let i = t.firstIndex(of: tag) { t.remove(at: i) } else { t.append(tag) }
        if t.isEmpty { d.removeValue(forKey: id) } else { d[id] = t }
        save(d)
    }

    static func move(old: String, new: String) {
        guard old != new else { return }
        var d = dict()
        if let t = d[old] { d.removeValue(forKey: old); d[new] = t; save(d) }
    }

    // 只回显"现有文件真正在用"的标签，按字母排序
    static func chips(ids: Set<String>) -> [String] {
        var set = Set<String>()
        for (id, ts) in dict() where ids.contains(id) { set.formUnion(ts) }
        return Array(set).sorted()
    }
}
