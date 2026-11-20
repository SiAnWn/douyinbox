import SwiftUI

// MARK: - 藏（本地仓库）：影｜剧｜音｜★｜私 (v1.10.104 IA 终局: 藏退 tab 收进场书架入口,
// 画段让位 QuickPic 外部项目(图仍在 Documents/画廊/ 一张不丢); 剧段=原场·书架 DramaView 并入)

struct StashHubView: View {
    @EnvironmentObject var app: AppState
    @State private var seg = 0

    var body: some View {
        // v1.10.104 摘掉自带 NavigationStack: 现在挂在场栈里(push 目的地), 防双层套娃
        VStack(spacing: 0) {
            Picker("", selection: $seg) {
                Text("影").tag(0)
                Text("剧").tag(1)
                Text("音").tag(2)
                Text("★").tag(3)      // 收藏: 用星避与 tab 名"藏"撞字
                Text("私").tag(4)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal], 14)
            .padding(.vertical, 8)

            Group {
                switch seg {
                case 0: LibraryView(kind: 0)
                case 1: DramaView()
                case 2: LibraryView(kind: 2)
                case 3: LibraryView(kind: 3)
                case 4: PrivateView()
                default: LibraryView(kind: 0)
                }
            }
        }
        .navigationTitle("藏")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// 画廊占位（P1：图叻引擎+图集媒体类型入驻）
struct GalleryStubView: View {
    var body: some View {
        ContentUnavailableView {
            Label("画廊 · 敬请期待", systemImage: "photo.stack")
        } description: {
            Text("图集媒体类型与「图叻」网页聚图引擎已在路上\n770+ 写真/福利站点规则整装待发")
        } actions: {
            NavigationLink {
                GalleryAboutView()
            } label: {
                Text("了解图叻计划")
                    .font(.callout)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(.tint.opacity(0.15)))
            }
        }
    }
}

struct GalleryAboutView: View {
    var body: some View {
        List {
            Section("图叻 · 网页图集引擎（P1/P2）") {
                Label("粘贴任意图集页链接 → 自动聚集全部分页大图 → 批量入库", systemImage: "wand.and.stars")
                Label("规则库驱动：770+ 站点选择器开箱即用（MIT 授权）", systemImage: "list.bullet.rectangle")
                Label("未收录站点走通用聚图兜底，WordPress 系通吃", systemImage: "square.stack.3d.up")
                Label("规则文件独立更新，不随 app 发版", systemImage: "arrow.triangle.2.circlepath")
            }
            Section("画廊分区") {
                Label("写真/图集统一存放，滑动看图", systemImage: "photo.on.rectangle")
                Label("敏感内容可直存私密区（FaceID）", systemImage: "lock.circle")
            }
        }
        .navigationTitle("图叻计划")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 匣（百宝匣）：内置浏览器柜（占位橱窗已清空）

struct BoxView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BoxBrowserView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("内置浏览器")
                                Text("书签速达 · 长按存图 · 记住登录")
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
                }
            }
            .navigationTitle("匣")
        }
    }
}
