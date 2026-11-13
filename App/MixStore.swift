import Foundation

// MARK: - 合集数据（免费公开接口，不耗 ifphp 配额）
struct MixEpisode {
    let id: String
    let title: String
    let embedded: URL?
    var num: Int = 0
}

struct MixData: Identifiable {
    let id: String          // mixID
    let name: String
    let eps: [MixEpisode]
}

enum MixAPI {
    static let iosUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    static func resolve(_ link: String) async -> String? {
        guard let u = RegexHelper.firstFullURL(link), let url = URL(string: u) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(iosUA, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
                c.resume(returning: (resp as? HTTPURLResponse)?.url?.absoluteString ?? u)
            }
            task.resume()
        }
    }

    static func mixID(from finalURL: String) -> String? {
        RegexHelper.firstGroup(finalURL, pattern: "/mix(?:/detail)?/(\\d{15,20})")
            ?? RegexHelper.firstGroup(finalURL, pattern: "mix_id=(\\d{15,20})")
            ?? RegexHelper.firstGroup(finalURL, pattern: "/collection/(\\d{15,20})")
    }

    static func fetch(mixID: String) async throws -> MixData {
        var eps: [MixEpisode] = []
        var cursor = 0
        var name = ""
        for _ in 0..<40 {   // 页上限护栏
            let u = "https://www.iesdouyin.com/aweme/v1/mix/aweme/?reflow_source=reflow_page"
                  + "&web_id=undefined&device_id=undefined&aid=1128&mix_id=\(mixID)"
                  + "&count=20&cursor=\(cursor)&device_type=&device_platform=web"
                  + "&publish_videocut=0&app=aweme&os=ios&ac=wifi"
            let d = try await getJSON(u)
            let lst = (d["aweme_list"] as? [[String: Any]]) ?? []
            for item in lst {
                guard let id = strOf(item["aweme_id"]) else { continue }
                let title = (item["desc"] as? String) ?? ""
                var emb: URL? = nil
                if let v = item["video"] as? [String: Any],
                   let pa = v["play_addr"] as? [String: Any],
                   let arr = pa["url_list"] as? [String], let first = arr.first {
                    emb = URL(string: first)
                }
                eps.append(MixEpisode(id: id, title: title.isEmpty ? "第\(eps.count + 1)集" : title, embedded: emb))
            }
            if name.isEmpty { name = (d["mix_name"] as? String) ?? "" }
            let hasMore = intOf(d["has_more"]) ?? ((d["has_more"] as? Bool == true) ? 1 : 0)
            cursor = intOf(d["cursor"]) ?? (cursor + lst.count)
            if lst.isEmpty || hasMore == 0 { break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        if eps.isEmpty { throw GError.failed("没读到合集内容（可能是付费合集或接口变动）") }
        for i in eps.indices { eps[i].num = i + 1 }
        if name.isEmpty {
            let du = "https://www.iesdouyin.com/aweme/v1/mix/detail/?reflow_source=reflow_page"
                   + "&web_id=undefined&device_id=undefined&aid=1128&mix_id=\(mixID)"
                   + "&device_type=&device_platform=web&app=aweme&os=ios&ac=wifi"
            if let d = try? await getJSON(du),
               let mi = d["mix_info"] as? [String: Any],
               let n = mi["mix_name"] as? String, !n.isEmpty { name = n }
        }
        return MixData(id: mixID, name: name.isEmpty ? "合集\(mixID.prefix(6))" : name, eps: eps)
    }

    private static func getJSON(_ u: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: u)!)
        req.setValue(iosUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.iesdouyin.com/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { throw GError.http(h.statusCode) }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GError.noData }
        return d
    }
}

// MARK: - 断点/追更清单：mixID -> [集ID: 相对路径]
enum MixManifest {
    static func map(_ mixID: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: "mixdl_\(mixID)") as? [String: String]) ?? [:]
    }
    static func record(_ mixID: String, epID: String, rel: String) {
        var m = map(mixID); m[epID] = rel
        UserDefaults.standard.set(m, forKey: "mixdl_\(mixID)")
    }
}

// MARK: - 后台下载会话：切去别的 app / 锁屏后 iOS 原生继续传输
final class BatchTransfer: NSObject, URLSessionDownloadDelegate {
    static let shared = BatchTransfer()
    private struct Pending { let cont: CheckedContinuation<URL, Error>; var dest: URL? }
    private var table: [Int: Pending] = [:]
    private let lock = NSLock()   // 主线程登记 vs 后台回调线程，双向访问需加锁

    private func reg(_ id: Int, _ p: Pending) { lock.lock(); table[id] = p; lock.unlock() }
    private func setDest(_ id: Int, _ d: URL) {
        lock.lock(); if var p = table[id] { p.dest = d; table[id] = p }; lock.unlock()
    }
    private func take(_ id: Int) -> Pending? { lock.lock(); defer { lock.unlock() }; return table.removeValue(forKey: id) }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.sian.douyinbox.batch")
        cfg.httpAdditionalHeaders = ["User-Agent": DouyinAPI.ua]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue(DouyinAPI.referer(for: url), forHTTPHeaderField: "Referer")
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            let t = session.downloadTask(with: req)
            reg(t.taskIdentifier, Pending(cont: c))
            t.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg_\(downloadTask.taskIdentifier).mp4")
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.moveItem(at: location, to: dest)) != nil {
            setDest(downloadTask.taskIdentifier, dest)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        guard let p = take(id) else { return }
        if let e = error { p.cont.resume(throwing: e) }
        else if let d = p.dest { p.cont.resume(returning: d) }
        else { p.cont.resume(throwing: GError.failed("传输结束但文件丢失")) }
    }
}

// 下载并发槽（最多3路）与引擎调用节拍/健康度
actor Slots {
    private var used = 0
    func acquire() async { while used >= 3 { try? await Task.sleep(nanoseconds: 250_000_000) }; used += 1 }
    func release() { if used > 0 { used -= 1 } }
}
actor ParseGate {
    private var next = Date()
    func space() async {
        let w = next.timeIntervalSinceNow
        if w > 0 { try? await Task.sleep(nanoseconds: UInt64(w * 1_000_000_000)) }
        next = Date().addingTimeInterval(4)   // ≥4秒间隔 → 天然 ≤15次/分
    }
}
actor EngineHealth {
    private var fails = 0
    func noteError() -> Int { fails += 1; return fails }
    func reset() { fails = 0 }
    func dead() -> Bool { fails >= 4 }
}
actor EpQueue {
    private var q: [MixEpisode]
    init(_ eps: [MixEpisode]) { q = eps }
    func take() -> MixEpisode? { q.isEmpty ? nil : q.removeFirst() }
}

// MARK: - 批量执行器（v1.3.1：后台会话 + 4 workers + 3并发下载）
@MainActor
final class BatchRunner: ObservableObject {
    enum Phase { case ready, running, done, failed }
    @Published var phase: Phase = .ready
    @Published var total = 0
    @Published var got = 0
    @Published var skipped = 0
    @Published var failed = 0
    @Published var current = ""

    private var cancelled = false
    func cancel() { cancelled = true }
    nonisolated func shouldStop() -> Bool { cancelled }   // worker 免切主线程读

    func start(mix: MixData, base: String, useEngine: Bool, folderName: String,
               onFinish: @escaping () -> Void) async {
        phase = .running; cancelled = false
        got = 0; skipped = 0; failed = 0; total = mix.eps.count
        current = ""

        let rec = MixManifest.map(mix.id)
        let pendingList = mix.eps.filter { ep in
            if let rel = rec[ep.id], SavePaths.exists(rel: rel) { return false }
            return true
        }
        skipped = total - pendingList.count

        let eng = EngineStore.current
        let realEngine = useEngine && eng.isIfphp
        let endpoint = eng == .svparse ? "svparse" : "dyjx"
        let apikey = KeyStore.value(for: eng)
        let folder = Naming.sanitize(folderName.isEmpty ? mix.name : folderName)

        let queue = EpQueue(pendingList)
        let slots = Slots(); let gate = ParseGate(); let health = EngineHealth()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(4, pendingList.count) {
                group.addTask { [weak self] in
                    while true {
                        guard let ep = await queue.take() else { break }
                        if self?.shouldStop() == true { break }
                        await self?.showCur(ep)
                        var dlURL: URL?
                        var useEngNow = realEngine
                        if useEngNow {
                            let dead = await health.dead()
                            useEngNow = !dead
                        }
                        if useEngNow {
                            while CallStats.current().minute >= CallStats.limits.minute {
                                if self?.shouldStop() == true { break }
                                try? await Task.sleep(nanoseconds: 15_000_000_000)
                            }
                            await gate.space()
                            do {
                                let r = try await ifphpParse(endpoint: endpoint, key: apikey,
                                    link: "https://www.douyin.com/video/\(ep.id)")
                                dlURL = r.options.first?.url
                                await health.reset()
                            } catch {
                                _ = await health.noteError()
                                dlURL = ep.embedded    // 引擎故障退内嵌
                            }
                        } else {
                            dlURL = ep.embedded
                        }
                        guard let u2 = dlURL else { await self?.addFail(); continue }
                        await slots.acquire()
                        do {
                            let file = try await BatchTransfer.shared.download(u2)
                            let rel = "\(base)/\(folder)/\(Naming.epName(num: ep.num, title: ep.title))"
                            let ok = SavePaths.write(file, rel: rel)
                            try? FileManager.default.removeItem(at: file)
                            if ok {
                                await self?.persist(mix.id, ep.id, rel)
                                await self?.addGot()
                            } else { await self?.addFail() }
                        } catch {
                            await self?.addFail()
                        }
                        await slots.release()
                    }
                }
            }
        }
        phase = cancelled ? .failed : .done
        if cancelled { current = "已取消（已下保留，再粘同链接续传）" }
        onFinish()
    }

    private func showCur(_ ep: MixEpisode) { current = "第 \(ep.num) 集 · \(String(ep.title.prefix(24)))" }
    private func addGot() { got += 1 }
    private func addFail() { failed += 1 }
    private func persist(_ mixID: String, _ epID: String, _ rel: String) { MixManifest.record(mixID, epID: epID, rel: rel) }
}
