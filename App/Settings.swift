import SwiftUI

// Key 存本机（Engines.swift 的 KeyStore 读写），不写进代码/仓库
// ——别人拉仓库构建不会消耗你的额度
// Quota / CallStats 已移至 Engines.swift（灵动岛扩展也需要链接）

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState
    @State private var engine = EngineStore.current
    @State private var dyjxInput = ""
    @State private var svInput = ""

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
                Section("灵动岛") {
                    Toggle("切到后台时常驻待命", isOn: $app.islandOn)
                    Text("退到后台后点岛上按钮=直接解析剪贴板，不用回 App；解析成功可一键跳回下载。iPhone 灵动岛设置里若关了实时活动则不显示。")
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
