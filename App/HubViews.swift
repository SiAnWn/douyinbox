import SwiftUI

// MARK: - 藏（书库中枢）：影｜剧｜私｜画廊 四段，子页各自内容直接挂到中枢导航

struct StashHubView: View {
    @EnvironmentObject var app: AppState
    @State private var seg = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $seg) {
                    Text("影").tag(0)
                    Text("剧").tag(1)
                    Text("私").tag(2)
                    Text("画廊").tag(3)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal], 14)
                .padding(.vertical, 8)

                Group {
                    switch seg {
                    case 0: LibraryView()
                    case 1: DramaView()
                    case 2: PrivateView()
                    default: GalleryHomeView()
                    }
                }
            }
        }
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

// MARK: - 匣（百宝匣）：未来工具的待租橱窗

struct BoxView: View {
    private struct Coming: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let phase: String
    }
    private let items: [Coming] = [
        .init(name: "图叻 · 网页图集", icon: "photo.stack", phase: "P1"),
        .init(name: "全站收藏 · 规则站速达", icon: "star.rectangle", phase: "P2"),
        .init(name: "追更订阅 · 新集推送", icon: "bell.badge", phase: "P2"),
        .init(name: "小红书图集定向", icon: "book", phase: "P2"),
        .init(name: "ReelShort / DramaBox 出海短剧", icon: "globe", phase: "P2"),
        .init(name: "NFC 贴卡一键收", icon: "wifi", phase: "P3"),
        .init(name: "OCR 截图提链接", icon: "text.viewfinder", phase: "P3"),
        .init(name: "铃声提取 · 白噪音", icon: "music.note", phase: "P3"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        DyFeedView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("抖音 · 沉浸刷流")
                                Text("推荐流原样上滑沉浸播（已根治系统全屏弹窗），绿键存无水印原画")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "play.tv").foregroundStyle(.pink)
                        }
                    }
                    NavigationLink {
                        BoxBrowserView(seed: "https://www.douyin.com/?recommend=1")
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("抖音 · 全屏推荐流")
                                Text("登录一次 → 无限刷；喜欢的视频点 ⬇ 无水印原画入库")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "music.note.list").foregroundStyle(.pink)
                        }
                    }
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
                }
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("匣子已开箱，好东西陆续上架")
                            Text("所有条目施工中标注，上架后此处直接可用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "gift.fill").foregroundStyle(.orange)
                    }
                }
                Section("待入驻") {
                    ForEach(items) { it in
                        Label {
                            HStack {
                                Text(it.name)
                                Spacer()
                                Text(it.phase)
                                    .font(.caption2).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(.quaternary))
                            }
                        } icon: {
                            Image(systemName: it.icon).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("匣")
        }
    }
}
