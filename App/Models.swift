import Foundation
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import CryptoKit

struct VideoItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let modDate: Date
    let size: Int
    var isAudio = false
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

struct AlbumItem: Identifiable, Hashable {
    let id: String          // 文件夹路径
    let title: String       // 去前缀后的名字
    let count: Int
    let cover: URL?         // 首图
    let modDate: Date
    let url: URL
    static func == (l: AlbumItem, r: AlbumItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum ImgKinds {
    static let exts = ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp"]
    static let prefixes = ["图集_"]     // 库根下图集文件夹识别前缀
    static func isImage(_ u: URL) -> Bool { exts.contains(u.pathExtension.lowercased()) }
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
            let ext = u.pathExtension.lowercased()
            let audExt = ["m4a", "mp3", "aac", "wav", "m4b", "flac"].contains(ext)
            var isAud = false, ok = false
            if let ct = v.contentType {
                if ct.conforms(to: .movie) || ct.conforms(to: .video) { ok = true }
                else if ct.conforms(to: .audio) || audExt { ok = true; isAud = true }
            } else {
                if ["mp4", "mov", "m4v", "ts", "tsv", "video"].contains(ext) { ok = true }
                else if audExt { ok = true; isAud = true }
            }
            guard ok else { continue }
            items.append(VideoItem(id: u.path, url: u,
                                   title: u.deletingPathExtension().lastPathComponent,
                                   modDate: v.contentModificationDate ?? .distantPast,
                                   size: v.fileSize ?? 0,
                                   isAudio: isAud))
        }
        return items
    }

    static func scanRootByDate() -> [VideoItem] {
        scan(in: root()).sorted { $0.modDate > $1.modDate }
    }

    // 图集：库根下 "图集_xxx" 文件夹，每夹一本
    static func imageFiles(in dir: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ImgKinds.isImage($0) && ($0.lastPathComponent != "说明.txt") }
            .sorted { a, b in
                let na = numKey(a.deletingPathExtension().lastPathComponent)
                let nb = numKey(b.deletingPathExtension().lastPathComponent)
                if na != nb { return na < nb }
                return a.lastPathComponent < b.lastPathComponent
            }
    }

    static func scanAlbums() -> [AlbumItem] {
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: root(), includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var out: [AlbumItem] = []
        for d in subs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue,
                  d.lastPathComponent.hasPrefix("图集_") else { continue }
            let files = imageFiles(in: d)
            guard !files.isEmpty else { continue }
            let mod = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let name = String(d.lastPathComponent.dropFirst("图集_".count))
            out.append(AlbumItem(id: d.path, title: name, count: files.count,
                                 cover: files.first, modDate: mod, url: d))
        }
        return out.sorted { $0.modDate > $1.modDate }
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
    private var genCount = 0
    private let diskDir: URL = {
        let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        return c
    }()

    init() {
        mem.countLimit = 250            // 几万条也不占爆内存，LRU 自动轮换
    }

    private nonisolated func diskKey(_ url: URL, _ mod: Double) -> String {
        let s = url.path + "@" + String(format: "%.0f", mod)
        let d = Insecure.MD5.hash(data: Data(s.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func shrunken(_ img: UIImage, maxW: CGFloat) -> UIImage {
        let s = img.size
        guard s.width > maxW else { return img }
        let r = maxW / max(s.width, 1)
        let newSize = CGSize(width: maxW, height: (s.height * r).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private nonisolated func purgeDiskIfNeeded() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: [
            .contentModificationDateKey, .fileSizeKey])) ?? []
        guard files.count > 4000 else { return }
        struct E: Comparable { let url: URL; let date: Date; static func < (a: E, b: E) -> Bool { a.date < b.date } }
        var es: [E] = []
        for f in files {
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey])
            es.append(E(url: f, date: v?.contentModificationDate ?? .distantPast))
        }
        es.sort()
        for e in es.prefix(es.count - 2500) { try? fm.removeItem(at: e.url) }
    }

    func image(_ url: URL) async -> UIImage? {
        let k = url.path as NSString
        if let c = mem.object(forKey: k) { return c }
        let mod = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                   as? Date) ?? .distantPast
        let df = diskDir.appendingPathComponent(diskKey(url, mod.timeIntervalSince1970))
        if let d = UIImage(contentsOfFile: df.path) {
            mem.setObject(d, forKey: k)
            return d
        }
        var img: UIImage?
        if ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp"].contains(url.pathExtension.lowercased()) {
            img = UIImage(contentsOfFile: url.path).map { shrunken($0, maxW: 320) }
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 320)
            if let res = try? await gen.image(at: .zero) {
                img = UIImage(cgImage: res.image)
            }
        }
        if let i = img {
            mem.setObject(i, forKey: k)
            if let dat = i.jpegData(compressionQuality: 0.72) {
                try? dat.write(to: df)
                genCount += 1
                if genCount >= 400 { genCount = 0; purgeDiskIfNeeded() }
            }
        }
        return img
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

    // 全库用过的标签名（含自建）
    static func allKnownTags() -> Set<String> {
        var s = Set<String>()
        for ts in dict().values { s.formUnion(ts) }
        return s
    }

    // 一次性覆盖设置某文件的全部标签
    static func setTags(_ id: String, _ tags: [String]) {
        var d = dict()
        let t = Array(Set(tags)).sorted()
        if t.isEmpty { d.removeValue(forKey: id) } else { d[id] = t }
        save(d)
    }

    // 只回显"现有文件真正在用"的标签，按字母排序
    static func chips(ids: Set<String>) -> [String] {
        var set = Set<String>()
        for (id, ts) in dict() where ids.contains(id) { set.formUnion(ts) }
        return Array(set).sorted()
    }
}
