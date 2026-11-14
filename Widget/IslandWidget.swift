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

// MARK: - 喵星人手办（纯手绘，会眨眼，岛永不更新所以随便动）

private struct Tri: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct CatFace: View {
    let size: CGFloat
    var body: some View {
        TimelineView(.periodic(from: .now, by: 3.3)) { ctx in
            // 每 3.3 秒眨一下眼（0.25s 闭眼帧）
            let blink = Int(ctx.date.timeIntervalSince1970 * 4) % 13 == 0
            ZStack {
                // ── 耳朵：大三角外橙内粉
                Tri().fill(LinearGradient(colors: [.orange, Color(red: 0.9, green: 0.5, blue: 0.1)],
                                          startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.46, height: size * 0.46)
                    .rotationEffect(.degrees(-10))
                    .offset(x: -size * 0.34, y: -size * 0.60)
                Tri().fill(LinearGradient(colors: [.orange, Color(red: 0.9, green: 0.5, blue: 0.1)],
                                          startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.46, height: size * 0.46)
                    .rotationEffect(.degrees(10))
                    .offset(x: size * 0.34, y: -size * 0.60)
                Tri().fill(Color(red: 1.0, green: 0.72, blue: 0.75))
                    .frame(width: size * 0.24, height: size * 0.24)
                    .rotationEffect(.degrees(-10))
                    .offset(x: -size * 0.33, y: -size * 0.52)
                Tri().fill(Color(red: 1.0, green: 0.72, blue: 0.75))
                    .frame(width: size * 0.24, height: size * 0.24)
                    .rotationEffect(.degrees(10))
                    .offset(x: size * 0.33, y: -size * 0.52)
                // ── 脑袋
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.25),
                                                  Color(red: 0.93, green: 0.52, blue: 0.10)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: size, height: size * 0.96)
                // 头顶虎斑三道
                ForEach(-1...1, id: \.self) { i in
                    Capsule()
                        .fill(Color(red: 0.72, green: 0.35, blue: 0.03))
                        .frame(width: size * 0.055, height: size * 0.16)
                        .rotationEffect(.degrees(Double(i) * 18))
                        .offset(x: CGFloat(i) * size * 0.14, y: -size * 0.38)
                }
                // ── 白色口鼻双球
                HStack(spacing: -size * 0.02) {
                    Circle().fill(Color.white).frame(width: size * 0.40, height: size * 0.32)
                    Circle().fill(Color.white).frame(width: size * 0.40, height: size * 0.32)
                }
                .offset(y: size * 0.20)
                // ── 眼睛（大黑瞳+双高光的亮闪）
                HStack(spacing: size * 0.30) {
                    eye(blink, size * 0.15)
                    eye(blink, size * 0.15)
                }
                .offset(y: -size * 0.06)
                // ── 粉鼻头（小圆三角）
                Tri()
                    .fill(Color(red: 1.0, green: 0.45, blue: 0.52))
                    .frame(width: size * 0.14, height: size * 0.11)
                    .rotationEffect(.degrees(180))
                    .offset(y: size * 0.12)
                // ── 嘴：白色球缝 + w
                Capsule().fill(Color(red: 0.85, green: 0.55, blue: 0.5))
                    .frame(width: size * 0.03, height: size * 0.10)
                    .offset(y: size * 0.22)
                // ── 腮红
                HStack(spacing: size * 0.72) {
                    Circle().fill(Color(red: 1.0, green: 0.45, blue: 0.5).opacity(0.45))
                        .frame(width: size * 0.16, height: size * 0.10)
                    Circle().fill(Color(red: 1.0, green: 0.45, blue: 0.5).opacity(0.45))
                        .frame(width: size * 0.16, height: size * 0.10)
                }
                .offset(y: size * 0.14)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func eye(_ blink: Bool, _ d: CGFloat) -> some View {
        if blink {
            Capsule().fill(Color.black.opacity(0.85))
                .frame(width: d * 2.4, height: d * 0.5)
        } else {
            ZStack {
                Ellipse().fill(Color.black.opacity(0.88))
                    .frame(width: d * 1.9, height: d * 2.3)
                Circle().fill(Color.white).frame(width: d * 0.75, height: d * 0.75)
                    .offset(x: -d * 0.35, y: -d * 0.45)
                Circle().fill(Color.white.opacity(0.8)).frame(width: d * 0.35, height: d * 0.35)
                    .offset(x: d * 0.30, y: d * 0.35)
            }
        }
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
                CatFace(size: 30)
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
                        CatFace(size: 40)
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
                CatFace(size: 16)
                    .padding(.trailing, 2)
            } minimal: {
                CatFace(size: 18)
            }
            // 长按岛 = 直接唤起盒子（进 app 自动读剪贴板 → 解析 → 秒跳回抖音）
            .widgetURL(URL(string: "douyinbox://go"))
        }
    }
}
