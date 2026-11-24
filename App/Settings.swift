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
    @State private var metaMsg = ""
    @State private var metaBusy = false

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
                    Button("重置红果匿名设备（被风控/冷却熔断时用）") {
                        hgBusy = true
                        Task {
                            if let c = Hongguo.client { try? await c.resetDevice() }
                            HGCurrent.clearSoftBlock()
                            hgMsg = "已换新匿名设备并解除线路熔断，可重试红果链接（配合开关一次飞行模式换 IP 更稳）"
                            hgBusy = false
                        }
                    }
                    .disabled(hgBusy)
                    if !hgMsg.isEmpty { Text(hgMsg).font(.caption).foregroundStyle(.secondary) }
                    Text("红果走专属引擎：链接粘贴即自动识别，免登录不耗 API 配额；出口 IP 被风控换节点即可。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("工具") {
                    NavigationLink {
                        BoxBrowserView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("内置浏览器")
                                Text("书签速达 · 长按存图 · 记住登录 · ✨ 图叻聚图")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "globe").foregroundStyle(.blue)
                        }
                    }
                    NavigationLink {
                        SniffView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("网页嗅探器")
                                Text("抖音短剧 1080p · 任意网页 m3u8/mp4 抓取入库")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "dot.radiowaves.right").foregroundStyle(.purple)
                        }
                    }
                    Button {
                        metaBusy = true
                        Task {
                            await SeriesMetaStore.backfill(app) { s in
                                Task { @MainActor in
                                    metaMsg = s
                                    if s.hasPrefix("补齐完成") { metaBusy = false }
                                }
                            }
                        }
                    } label: {
                        Label("补齐旧剧档案（演员·评分·分类）", systemImage: "person.2.badge.plus")
                    }
                    .disabled(metaBusy)

                    Button {
                        HGCurrent.clearSoftBlock()
                        UserDefaults.standard.removeObject(forKey: "hgLiftDevice")
                        UserDefaults.standard.removeObject(forKey: "hgTtwid")
                        HGWater.resetP720Fail()
                        metaMsg = "熔断已解除 · 设备与门票已丢弃 · 换个海外节点再投"
                    } label: {
                        Label("红果线路急救包（解除熔断+丢设备+换门票）", systemImage: "cross.case.fill")
                    }
                    .disabled(metaBusy)
                    if !metaMsg.isEmpty { Text(metaMsg).font(.caption).foregroundStyle(.secondary) }
                    Button {
                        metaBusy = true
                        Task {
                            await DanmakuStore.backfill(app) { s in
                                Task { @MainActor in
                                    metaMsg = s
                                    if s.hasPrefix("弹幕补齐") { metaBusy = false }
                                }
                            }
                        }
                    } label: {
                        Label("给旧剧补弹幕（离线飘屏素材）", systemImage: "text.bubble")
                    }
                    .disabled(metaBusy)
                    Button {
                        metaBusy = true
                        Task {
                            await DanmakuStore.reharvest(app) { s in
                                Task { @MainActor in
                                    metaMsg = s
                                    if s.hasPrefix("重采完成") || s.hasPrefix("没有已有") { metaBusy = false }
                                }
                            }
                        }
                    } label: {
                        Label("换马甲重采弹幕（给已有弹幕加餐）", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(metaBusy)
                    Text("服务器给每台设备发的精选套餐各不相同——这按钮给已有弹幕的存量剧逐部换设备马甲再榨干扫一轮，新料去重后增量并入（旧的永不丢）。每部约半分钟到几分钟，中途退出已收部分已落盘。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("弹幕随档案一起自动入库；这里给已经下过的旧剧补拉（每部约 2-5 分钟后台跑）。拉完后坊里/观看全集自动飘，全程离线。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("整剧下载完成会自动领档案；这里给已经下过的旧剧按剧名补一份（一部一次查询，全程匿名不耗配额）。坊页底条会显示演员·评分。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("灵动岛") {
                    Toggle("切到后台时常驻待命", isOn: $app.islandOn)
                    Toggle("下载完工自动跳回抖音（单条/合集批量都算完工）", isOn: $app.autoReturn)
                    Toggle("下载完成发横幅通知", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "doneNotify") as? Bool ?? true },
                        set: { v in
                            UserDefaults.standard.set(v, forKey: "doneNotify")
                            if v { UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                        }))
                    Text("岛状态词由系统择机刷新；横幅通知则当下即达。复制链接→点一下岛→勾栏自动解析、自动下最高画质、1.5秒后把你送回抖音，下载在后台继续。")
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
