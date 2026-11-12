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
    static func dir() -> URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func scan() -> [VideoItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .contentTypeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir(), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
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
        return items.sorted { $0.modDate > $1.modDate }
    }

    static func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: id) }
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
