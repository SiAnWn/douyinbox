import SwiftUI
import LocalAuthentication

struct PrivateView: View {
    @EnvironmentObject var app: AppState
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if !app.privateUnlocked {
                    lockView
                } else if app.privates.isEmpty {
                    ContentUnavailableView("私密为空",
                                           systemImage: "lock",
                                           description: Text("把私密视频放进 文件 › DouyinBox › 私密 文件夹"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(app.privates) { v in
                                Button { app.playInPlace(v) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Thumb(url: v.url)
                                            .frame(height: 160)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(v.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(app.privateUnlocked ? "私密 · \(app.privates.count)" : "私密")
            .onAppear { if !app.privateUnlocked { authenticate() } }
            .refreshable { app.refreshPrivates() }
        }
    }

    private var lockView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("私密内容需要面容验证").font(.headline)
            Button { authenticate() } label: {
                Text("验证面容").padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Capsule().fill(.tint)).foregroundStyle(.white)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        let policy: LAPolicy
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            policy = .deviceOwnerAuthentication
        } else {
            app.privateUnlocked = false
            return
        }
        ctx.evaluatePolicy(policy, localizedReason: "查看私密视频") { ok, _ in
            DispatchQueue.main.async { app.privateUnlocked = ok }
        }
    }
}
