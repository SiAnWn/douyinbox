import SwiftUI

// 接口 Key 只存本机（不写进代码/仓库），别人拉代码构建不会消耗你的额度
enum KeyStore {
    private static let key = "ifphpApiKey"
    static var value: String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func set(_ v: String) {
        UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }
}

struct Quota: Equatable {
    var minute = 0, hour = 0, day = 0, month = 0
    static let zero = Quota()
}

// 本机调用计数（分/时/日/月），可手动校正 + 自动累加
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
    @State private var keyInput = ""
    @State private var quota = Quota.zero
    @State private var qMin = ""
    @State private var qHour = ""
    @State private var qDay = ""
    @State private var qMonth = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("接口 Key") {
                    SecureField("粘贴你的 ifphp 接口 Key", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存 Key") { KeyStore.set(keyInput); saved = true }
                    Text(saved ? "已保存，现在可以解析了"
                               : (KeyStore.value.isEmpty ? "尚未设置 Key（解析前请先填）" : "已设置 Key（可更新）"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Key 只存本机、不写进代码；别人拉仓库构建不会消耗你的额度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("接口配额（可手动校正，自动累加本机调用）") {
                    quotaRow("本分钟", $qMin, .minute, CallStats.limits.minute)
                    quotaRow("本小时", $qHour, .hour, CallStats.limits.hour)
                    quotaRow("今日", $qDay, .day, CallStats.limits.day)
                    quotaRow("本月", $qMonth, .month, CallStats.limits.month)
                    Text("上限：15/分 · 600/时 · 8000/日 · 150000/月。到下一个周期自动归零。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { keyInput = KeyStore.value; refreshQuota() }
        }
    }

    private func refreshQuota() {
        let q = CallStats.current(); quota = q
        qMin = "\(q.minute)"; qHour = "\(q.hour)"; qDay = "\(q.day)"; qMonth = "\(q.month)"
    }

    @ViewBuilder
    private func quotaRow(_ label: String, _ text: Binding<String>, _ w: CallStats.Window, _ limit: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .frame(width: 72).border(Color.secondary.opacity(0.35), width: 1)
            Text("/\(limit)").font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: text.wrappedValue) { nv in
            if let v = Int(nv) { CallStats.set(w, v); quota = CallStats.current() }
        }
    }
}
