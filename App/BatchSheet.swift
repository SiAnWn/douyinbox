import SwiftUI

struct BatchSheet: View {
    let mix: MixData
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = BatchRunner()
    @State private var base = UserDefaults.standard.string(forKey: "batchBase") ?? "短剧"
    @State private var useEngine = EngineStore.current.isIfphp
    @State private var existing = 0

    private var isWebEngine: Bool { EngineStore.current == .web }

    var body: some View {
        NavigationStack {
            Form {
                Section("合集") {
                    Text(mix.name).font(.headline)
                    Text("\(mix.eps.count) 集 · 本机已有 \(existing) 集 · 待下 \(mix.eps.count - existing) 集")
                        .font(.footnote).foregroundStyle(.secondary)
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
                        Picker("模式", selection: $useEngine) {
                            Text("原画批量（每集 1 次配额）").tag(true)
                            Text("免费快速（内嵌约720p，0 配额）").tag(false)
                        }
                        .pickerStyle(.inline)
                        .disabled(runner.phase == .running)
                    }
                }
                Section("进度") {
                    ProgressView(value: Double(min(runner.got + runner.skipped + runner.failed, runner.total)),
                                 total: Double(max(runner.total, 1)))
                    Text(runner.current.isEmpty ? "待开始" : runner.current)
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("已下 \(runner.got) · 跳过 \(runner.skipped) · 失败 \(runner.failed)")
                        .font(.footnote).foregroundStyle(.secondary)
                    switch runner.phase {
                    case .ready:
                        Button("开始批量（补下缺失集）") {
                            UserDefaults.standard.set(base, forKey: "batchBase")
                            Task { await runner.start(mix: mix, base: base,
                                useEngine: useEngine && !isWebEngine,
                                folderName: mix.name,
                                onFinish: { app.refreshDramaSeries(); app.refreshPrivateSeries(); app.refresh() }) }
                        }
                    case .running:
                        Button("停止", role: .destructive) { runner.cancel() }
                    case .done:
                        Text("完成：下 \(runner.got) 集，跳过 \(runner.skipped) 集"
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
                if isWebEngine { useEngine = false }
            }
        }
    }
}
