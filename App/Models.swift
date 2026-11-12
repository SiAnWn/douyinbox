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
                ?? (u.pathExtension.lowercased() == "mp4")
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
