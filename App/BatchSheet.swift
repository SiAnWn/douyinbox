import SwiftUI

struct BatchSheet: View {
    let mix: MixData
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = BatchRunner()
    @State private var base = UserDefaults.standard.string(forKey: "batchBase") ?? "短剧"
    @State private var mode = -1   // 0 内嵌免费 1 多平台API(不限量) 2 抖音原画(配额)
    @State private var existing = 0
    @State private var subbed = false

    private var isWebEngine: Bool { EngineStore.current == .web }
    private var junkCount: Int { mix.eps.filter { $0.durMs > 0 && $0.durMs < 20_000 }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section("合集") {
                    Text(mix.name).font(.headline)
                    Text("\(mix.eps.count) 集 · 本机已有 \(existing) 集 · 待下 \(mix.eps.count - existing - junkCount) 集"
                         + (junkCount > 0 ? "\n⚠️ \(junkCount) 集是官方卡片/预告碎料（已自动跳过，去抖音或红果 App 看）" : ""))
                        .font(.footnote).foregroundStyle(junkCount > 0 ? .orange : .secondary)
                }
                Section {
                    Button {
                        if subbed {
                            SubscriptionStore.remove(mix.id)
                        } else {
                            SubscriptionStore.add(mixID: mix.id, title: mix.name, base: base)
                        }
                        subbed.toggle()
                        app.loadSubs()
                    } label: {
                        Label(subbed ? "已订阅 · 点一下退订（打开App自动检测新集）"
                                     : "订阅此合集（自动发现新集，一键追更）",
                              systemImage: subbed ? "bell.fill" : "bell")
                    }
                    .foregroundStyle(subbed ? Color.orange : Color.accentColor)
                }
                Section("存放位置") {
                    Picker("位置", selection: $base) {
                        Text("短剧/\(mix.name)").tag("短剧")
                        Text("私密/\(mix.name)").tag("私密")
                    }
                    .pickerStyle(.inline)
                    .disabled(runner.phase == .running)
                }
                Section("下载模式") {
                    if isWebEngine {
                        Text("浏览器引擎：批量走免费内嵌地址（约720p，不耗配额）")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("模式", selection: $mode) {
                            Text("多平台 API（不限量·推荐）").tag(1)
                            Text("抖音原画（每集 1 次配额）").tag(2)
                            Text("免费快速（内嵌约720p，0 配额）").tag(0)
                        }
                        .pickerStyle(.inline)
                        .disabled(runner.phase == .running)
                    }
                }
                Section("进度") {
                    ProgressView(value: Double(min(runner.got + runner.failed, max(runner.total, 1))),
                                 total: Double(max(runner.total, 1)))
                    Text(runner.current.isEmpty ? "待开始" : runner.current)
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("已下 \(runner.got) · 跳过 \(runner.skipped) · 碎料拒收 \(runner.junk) · 失败 \(runner.failed)")
                        .font(.footnote).foregroundStyle(.secondary)
                    switch runner.phase {
                    case .ready:
                        Button("开始批量（补下缺失集）") {
                            UserDefaults.standard.set(base, forKey: "batchBase")
                            Task { await runner.start(mix: mix, base: base,
                                useEngine: (mode == 1 || mode == 2) && !isWebEngine,
                                folderName: mix.name,
                                apiEngine: mode == 1 ? .svparse : (mode == 2 ? .dyjx : nil),
                                onFinish: { app.refreshDramaSeries(); app.refreshPrivateSeries(); app.refresh() }) }
                        }
                    case .running:
                        Button("停止", role: .destructive) { runner.cancel() }
                    case .done:
                        Text("完成：下 \(runner.got) 集，跳过 \(runner.skipped) 集"
                             + (runner.junk > 0 ? "，碎料拒收 \(runner.junk) 集（这几集抖音只下发卡片，去红果App看）" : "")
                             + (runner.failed > 0 ? "，失败 \(runner.failed) 集" : "")).font(.callout)
                        Button("完成") { dismiss() }
                    case .failed:
                        Text(runner.current).font(.callout)
                        Button("完成") { dismiss() }
                    }
                }
            }
            .navigationTitle("合集批量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { if runner.phase != .running { dismiss() } }
                }
            }
            .onAppear {
                let rec = MixManifest.map(mix.id)
                existing = rec.values.filter { SavePaths.exists(rel: $0) }.count
                if mode < 0 { mode = isWebEngine ? 0 : (mix.freeDefault ? 1 : (EngineStore.current.isIfphp ? 2 : 0)) }
                subbed = SubscriptionStore.exists(mix.id)
            }
        }
    }
}
