import UIKit
import UniformTypeIdentifiers

// 分享扩展：抖音/任意App → 分享 → 「抖音盒子」→ 链接直接解析上岛，零剪贴板依赖
@objc(ShareRootViewController)
final class ShareRootViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let sp = UIActivityIndicatorView(style: .large)
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.center = view.center
        sp.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                               .flexibleTopMargin, .flexibleBottomMargin]
        sp.startAnimating()
        view.addSubview(sp)

        let lbl = UILabel()
        lbl.text = "盒子：链接解析中…"
        lbl.textColor = .secondaryLabel
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.center = CGPoint(x: view.center.x, y: view.center.y + 60)
        lbl.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(lbl)

        let inputs = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { @MainActor in
            let link = await Self.pickLink(inputs)
            if link.isEmpty {
                BoxIsland.ensureStandby()
                BoxIsland.update { $0.phase = "fail"; $0.note = "分享内容里没找到链接" }
                lbl.text = "没找到链接 😅"
            } else {
                await BoxIsland.parseAndShow(link)
                lbl.text = "已送上灵动岛 ✓"
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.finish()
        }
    }

    @objc func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    static func pickLink(_ items: [NSExtensionItem]) async -> String {
        for item in items {
            guard let atts = item.attachments else { continue }
            for prov in atts {
                // 1) URL 对象通道（分享面板的“链接”多数走这条）
                if let u = await loadURL(prov) {
                    let s = u.absoluteString
                    if s.hasPrefix("http") { return DouyinAPI.extractURL(s) ?? s }
                }
                // 2) 纯文本通道
                for t in ["public.utf8-plain-text", "public.plain-text"] {
                    if !prov.hasItemConformingToTypeIdentifier(t) { continue }
                    if let s = await loadString(prov, t), s.contains("http") {
                        return DouyinAPI.extractURL(s) ?? s
                    }
                }
            }
        }
        return ""
    }

    static func loadURL(_ prov: NSItemProvider) async -> URL? {
        guard prov.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { c in
            _ = prov.loadObject(ofClass: URL.self) { obj, _ in
                c.resume(returning: obj)
            }
        }
    }

    static func loadString(_ prov: NSItemProvider, _ type: String) async -> String? {
        await withCheckedContinuation { c in
            _ = prov.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                let s = data.flatMap { String(data: $0, encoding: .utf8) }
                c.resume(returning: s)
            }
        }
    }
}
