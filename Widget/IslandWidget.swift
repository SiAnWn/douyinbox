import SwiftUI
import ActivityKit
import WidgetKit
import AppIntents

@main
struct IslandBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        BoxLiveActivity()
        if #available(iOS 18.0, *) {
            BoxControl()
        }
    }
}

// 控制中心磁贴：一按=后台解析剪贴板（iOS18+）
@available(iOS 18.0, *)
struct BoxControl: ControlWidget {
    static let kind = "com.sian.DouyinBox.parse-clip"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ParseClipIntent()) {
                Label("解析剪贴板", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("盒子：解析剪贴板")
        .description("读取剪贴板里的抖音链接，后台解析并下载，完成时横幅通知")
    }
}

// MARK: - 静态笑脸（极简定妆版：无动画零刷新负担）

private struct SmileFace: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "face.smiling")
            .font(.system(size: size))
            .foregroundStyle(.orange)
    }
}

struct BoxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BoxActivity.self) { ctx in
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.state.title.isEmpty ? "抖音盒子" : ctx.state.title)
                        .font(.headline).lineLimit(1)
                    Text(ctx.state.note.isEmpty ? "点一下岛开始下载" : ctx.state.note)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SmileFace(size: 20)
                    .padding(.trailing, 4)
                if ctx.state.phase == "parsed" {
                    Button("下载", intent: IslandDownloadIntent(link: ctx.state.link))
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
            }
            .padding(12)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.author.isEmpty ? "抖音盒子" : s.author)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(s.title.isEmpty ? "点我进盒子" : s.title)
                            .font(.headline).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack {
                        Spacer()
                        SmileFace(size: 34)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        if !s.note.isEmpty {
                            Text(s.note).font(.caption2)
                                .foregroundStyle(s.phase == "fail" ? Color.red : Color.secondary)
                                .lineLimit(2).multilineTextAlignment(.center)
                        }
                        HStack(spacing: 10) {
                            Button("解析剪贴板", intent: ParseClipIntent())
                                .buttonStyle(.borderedProminent).tint(.blue)
                            if s.phase == "parsed" {
                                Button("开始下载", intent: IslandDownloadIntent(link: s.link))
                                    .buttonStyle(.borderedProminent).tint(.orange)
                            }
                            Button("待命", intent: IslandStandbyIntent())
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            } compactTrailing: {
                SmileFace(size: 13)
                    .padding(.trailing, 2)
            } minimal: {
                SmileFace(size: 15)
            }
            // 长按岛 = 直接唤起盒子（进 app 自动读剪贴板 → 解析 → 秒跳回抖音）
            .widgetURL(URL(string: "douyinbox://go"))
        }
    }
}
