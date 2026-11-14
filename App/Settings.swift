import SwiftUI
import UserNotifications

// Key 存本机（Engines.swift 的 KeyStore 读写），不写进代码/仓库
// ——别人拉仓库构建不会消耗你的额度
// Quota / CallStats 已移至 Engines.swift（灵动岛扩展也需要链接）

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState
    @State private var engine = EngineStore.current
    @State private var dyjxInput = ""
    @State private var svInput = ""
    @State private var hgBusy = false
    @State private var hgMsg = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("解析引擎") {
                    Picker("引擎", selection: $engine) {
                        ForEach(Engine.allCases, id: \.self) { e in
                            Text(e.label).tag(e)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text("合集列表始终免费（公开接口）；批量原画仅 API 引擎支持。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let dbg = UserDefaults.standard.string(forKey: "boxIslandDiag") {
                    Section("岛诊断") {
                        Text(dbg).font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section("红果短剧") {
                    Button("重置红果匿名设备（被风控时空结果再用）") {
                        hgBusy = true
                        Task {
                            if let c = Hongguo.client { try? await c.resetDevice() }
                            hgMsg = "已换新匿名设备，可重试红果链接"
                            hgBusy = false
                        }
                    }
                    .disabled(hgBusy)
                    if !hgMsg.isEmpty { Text(hgMsg).font(.caption).foregroundStyle(.secondary) }
                    Text("红果走专属引擎：链接粘贴即自动识别，免登录不耗 API 配额；出口 IP 被风控换节点即可。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("灵动岛") {
                    Toggle("切到后台时常驻待命", isOn: $app.islandOn)
                    Toggle("一键下载后自动跳回抖音", isOn: $app.autoReturn)
                    Toggle("下载完成发横幅通知", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "doneNotify") as? Bool ?? true },
                        set: { v in
                            UserDefaults.standard.set(v, forKey: "doneNotify")
                            if v { UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                        }))
                    Text("岛状态词由系统择机刷新；横幅通知则当下即达。复制链接→点一下岛→盒子自动解析、自动下最高画质、1.5秒后把你送回抖音，下载在后台继续。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("接口 Key（各产品独立，只存本机）") {
                    SecureField("抖音原画引擎 Key（dyjx）", text: $dyjxInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存 抖音 Key") { KeyStore.set(dyjxInput, for: .dyjx) }
                    SecureField("多平台引擎 Key（svparse）", text: $svInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存 多平台 Key") { KeyStore.set(svInput, for: .svparse) }
                    Text("当前：\(engine.label)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                dyjxInput = KeyStore.value(for: .dyjx)
                svInput = KeyStore.value(for: .svparse)
            }
            .onChange(of: engine) { nv in EngineStore.current = nv }
        }
    }
}
