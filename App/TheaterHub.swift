import SwiftUI
import Openhongguo

// MARK: - 红果剧场（A 菜, v1.10.15）: 藏→"场" 分段 = 匿名目录 browsing
// 发现/搜索 → 详情(海报·演员·评分·简介) → 一键整剧下载(踢回拾页发车 hongguoRun)。
// 全程只吃目录接口(播放闸从未波及), 匿名免费; 下载/弹幕/档案链路全自动复用。

struct HgWant: Hashable {
    let sid: String
    let title: String
}

@MainActor
final class TheaterVM: ObservableObject {
    @Published var rows: [SeriesSummary] = []
    @Published var query = ""
    @Published var busy = false
    @Published var note = ""

    func load() {
        guard !busy else { return }
        busy = true; note = ""
        Task {
            defer { busy = false }
            guard let c = Hongguo.client else { note = "红果引擎未就绪"; return }
            if let pg = try? await Hongguo.attempt(c, { try await c.discover() }) {
                rows = pg.items
                if rows.isEmpty { note = "剧场暂时空手（风控抖动，下拉再来）" }
            } else { note = "目录口这次没搭手，下拉重试" }
        }
    }

    func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { load(); return }
        busy = true; note = ""
        Task {
            defer { busy = false }
            guard let c = Hongguo.client else { note = "红果引擎未就绪"; return }
            if let pg = try? await Hongguo.attempt(c, { try await c.search(q) }) {
                rows = pg.items
                if rows.isEmpty { note = "搜不到「\(q)」，换个词试试" }
            } else { note = "搜索没成，稍后再试" }
        }
    }
}

struct TheaterHomeView: View {
    @StateObject private var vm = TheaterVM()

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("搜红果新剧 / 剧名", text: $vm.query)
                        .textFieldStyle(.plain)
                        .onSubmit { vm.run() }
                    Button("搜索") { vm.run() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
                .padding(.vertical, 2)
            }
            if !vm.note.isEmpty {
                Section { Text(vm.note).font(.caption).foregroundStyle(.secondary) }
            }
            if !vm.rows.isEmpty {
                Section {
                    ForEach(vm.rows, id: \.id) { s in
                        NavigationLink(value: HgWant(sid: s.id, title: s.title)) {
                            HStack(spacing: 10) {
                                AsyncImage(url: URL(string: s.coverUrl)) { $0.resizable().scaledToFill() }
                                    placeholder: { Color.gray.opacity(0.15) }
                                    .frame(width: 52, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title).font(.subheadline).lineLimit(1)
                                    HStack(spacing: 0) {
                                        if !s.category.isEmpty {
                                            Text(s.category).font(.caption).foregroundStyle(.secondary)
                                            Text(" · ").font(.caption).foregroundStyle(.tertiary)
                                        }
                                        Text(s.episodeCount > 0 ? "全\(s.episodeCount)集" : "短剧")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(s.description).font(.caption2)
                                        .foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("红果剧场 · 匿名目录 · 点进去可整剧下载")
                }
            }
        }
        .overlay { if vm.busy { ProgressView().controlSize(.large) } }
        .task { if vm.rows.isEmpty { vm.load() } }
        .refreshable { vm.load() }
        .navigationDestination(for: HgWant.self) { w in TheaterDetailView(want: w) }
    }
}

struct TheaterDetailView: View {
    let want: HgWant
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var s: Series?
    @State private var busy = false

    var body: some View {
        List {
            if let sv = s {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: URL(string: sv.coverUrl)) { $0.resizable().scaledToFill() }
                            placeholder: { Color.gray.opacity(0.15) }
                            .frame(width: 96, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sv.title).font(.headline)
                            ForEach(rowLines(sv), id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !sv.description.isEmpty {
                    Section("简介") { Text(sv.description).font(.callout) }
                }
                Section {
                    Button {
                        app.hgWant = want
                        app.selection = .pick
                        dismiss()
                    } label: {
                        Label("整剧下载（红果 1080P）", systemImage: "arrow.down.circle")
                            .font(.body.weight(.bold))
                    }
                    Text("送回拾页自动发车；档案+弹幕一并领回。约 \(max(1, sv.episodeCount)) 集，一部大致 1GB 上下，建议 Wi-Fi。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(busy ? "取详情中…" : "详情加载中…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("剧场详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            busy = true
            defer { busy = false }
            guard let c = Hongguo.client else { return }
            s = try? await Hongguo.attempt(c, { try await c.getSeries(want.sid) })
        }
    }

    private func rowLines(_ sv: Series) -> [String] {
        var out: [String] = []
        for r in sv.rows {
            if r.text.isEmpty { continue }
            if r.kind == InfoKind.twoActors || r.kind == InfoKind.score || r.kind == InfoKind.category {
                out.append(r.text)
            }
        }
        if sv.episodeCount > 0 { out.append("全\(sv.episodeCount)集") }
        if sv.heat > 0 {
            out.append(sv.heat >= 10_000 ? "热度 \((sv.heat + 5_000) / 10_000)万" : "热度 \(sv.heat)")
        }
        if !sv.rightText.isEmpty { out.append(sv.rightText) }
        return out
    }
}
