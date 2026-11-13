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

// 控制中心磁贴：一按=后台解析剪贴板并上岛（iOS18+）
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
        .description("读取剪贴板里的抖音链接，后台解析并送上灵动岛，无需打开App")
    }
}

// 胶囊图标：parsing 且已有进度时改用下载箭头（环+箭头组合），否则按阶段
private func islandIcon(_ phase: String, _ pct: Int) -> String {
    switch phase {
    case "parsing": return pct > 0 ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath"
    case "parsed":  return "checkmark.circle.fill"
    case "fail":    return "exclamationmark.circle.fill"
    default:        return "arrow.down.circle"
    }
}

// 胶囊底边进度线（左右两段拼接）：track 淡灰 + 橙色已下载段
private func islandBar(_ frac: Double) -> some View {
    ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white.opacity(0.30))
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.orange)
                .frame(width: max(0, min(1, CGFloat(frac))) * g.size.width)
        }
    }
    .frame(height: 3)
}

private func islandMark(_ s: BoxActivity.ContentState) -> String {
    switch s.phase {
    case "parsing": return s.pct > 0 ? "\(s.pct)%" : "…"
    case "parsed":  return "✓"
    case "fail":    return "!"
    default:        return "待"
    }
}

private func islandSub(_ s: BoxActivity.State) -> String {
    switch s.phase {
    case "parsing": return "正在解析剪贴板…"
    case "parsed":  return [s.quality, s.note].filter { !$0.isEmpty }.joined(separator: " · ")
    case "fail":    return s.note
    default:        return "复制抖音链接后点我"
    }
}

struct BoxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BoxActivity.self) { ctx in
            HStack(spacing: 10) {
                Image(systemName: islandIcon(ctx.state.phase, ctx.state.pct))
                    .font(.title3)
                    .foregroundStyle(ctx.state.phase == "parsed" ? Color.green
                                       : ctx.state.phase == "fail" ? Color.red : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.state.title.isEmpty ? "抖音盒子 · 待命" : ctx.state.title)
                        .font(.headline).lineLimit(1)
                    Text(islandSub(ctx.state))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
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
                        Text(s.title.isEmpty ? "待命中" : s.title)
                            .font(.headline).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        if !s.quality.isEmpty {
                            Text(s.quality).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                ZStack {
                    if s.phase == "parsing" && s.pct > 0 {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 1.4)
                            .frame(width: 18, height: 18)
                        Circle()
                            .trim(from: 0, to: CGFloat(s.pct) / 100.0)
                            .stroke(Color.orange,
                                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 18, height: 18)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                    } else {
                        // 无衬底裸符号：宽度≤14pt，绝不与镜头打架
                        switch s.phase {
                        case "parsed":
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                        case "fail":
                            Image(systemName: "exclamationmark")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.red)
                        case "parsing":
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        default:
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(.orange)
                        }
                    }
                }
            } compactTrailing: {
                Text("")
            } minimal: {
                Image(systemName: "square.stack.3d.down.right.fill")
            }
        }
    }
}

// 环+中心状态（给进度专属岛用：小圆气泡里完整可见）
private struct ProgRing: View {
    let pct: Int
    let done: Bool
    let failed: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.28), lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: done ? 1 : CGFloat(max(2, pct)) / 100.0)
                .stroke(done ? Color.green : failed ? Color.red : Color.orange,
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
            } else if failed {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
            } else {
                Text("\(pct)")
                    .font(.system(size: 8, weight: .bold)).monospacedDigit()
            }
        }
        .frame(width: 26, height: 26)
    }
}

// 进度专属岛：与主岛并存时，系统把它挂成独立小圆气泡（minimal 展示）——镜头完全挡不到
struct BoxProgressLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BoxProgressActivity.self) { ctx in
            let s = ctx.state
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title.isEmpty ? "盒子下载" : s.title)
                    .font(.headline).lineLimit(1)
                ProgressView(value: Double(s.pct), total: 100)
                    .tint(s.done ? Color.green : s.failed ? Color.red : Color.orange)
                Text(s.done ? "✓ 下载完成" : s.failed ? "✗ 下载失败" : "下载中 \(s.pct)%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(s.title).font(.caption).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.done ? "完成" : s.failed ? "失败" : "\(s.pct)%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(s.done ? Color.green : s.failed ? Color.red : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: Double(s.pct), total: 100)
                        .tint(s.done ? Color.green : s.failed ? Color.red : Color.orange)
                }
            } compactLeading: {
                ProgRing(pct: s.pct, done: s.done, failed: s.failed)
            } compactTrailing: {
                if !s.done && !s.failed {
                    Text("\(s.pct)%")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                }
            } minimal: {
                ProgRing(pct: s.pct, done: s.done, failed: s.failed)
            }
        }
    }
}