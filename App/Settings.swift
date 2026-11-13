import SwiftUI

// Key 存本机（Engines.swift 的 KeyStore 读写），不写进代码/仓库
// ——别人拉仓库构建不会消耗你的额度

struct Quota: Equatable {
    var minute = 0, hour = 0, day = 0, month = 0
    static let zero = Quota()
}

// 本机调用计数（分/时/日/月，两个 ifphp 引擎共用计数）
enum CallStats {
    static let limits = (minute: 15, hour: 600, day: 8000, month: 150000)
    private static let key = "apiCallCounts"

    private static func bucketKeys(_ now: Date = Date()) -> (String, String, String, String) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let ymdhm = String(format: "%04d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        let s = Array(ymdhm)
        return ("m_" + String(s[0..<12]), "h_" + String(s[0..<10]), "d_" + String(s[0..<8]), "mo_" + String(s[0..<6]))
    }

    static func current() -> Quota {
        let d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        let k = bucketKeys()
        var q = Quota()
        q.minute = d[k.0] ?? 0; q.hour = d[k.1] ?? 0; q.day = d[k.2] ?? 0; q.month = d[k.3] ?? 0
        return q
    }

    static func record() {
        let q = current(); let k = bucketKeys()
        UserDefaults.standard.set([k.0: q.minute + 1, k.1: q.hour + 1, k.2: q.day + 1, k.3: q.month + 1], forKey: key)
    }

    static func blockReason() -> String? {
        let q = current()
        if q.minute >= limits.minute { return "本分钟已达 \(limits.minute) 次，等下一分钟" }
        if q.hour >= limits.hour { return "本小时已达 \(limits.hour) 次" }
        if q.day >= limits.day { return "今日已达 \(limits.day) 次" }
        if q.month >= limits.month { return "本月已达 \(limits.month) 次" }
        return nil
    }

    enum Window { case minute, hour, day, month }
    static func set(_ w: Window, _ value: Int) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        let k = bucketKeys()
        let t = w == .minute ? k.0 : w == .hour ? k.1 : w == .day ? k.2 : k.3
        d[t] = max(0, value)
        UserDefaults.standard.set(d, forKey: key)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
