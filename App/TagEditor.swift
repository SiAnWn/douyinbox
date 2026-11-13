import SwiftUI

// 标签多选编辑器：点选任意多个，支持当场新建，右上保存
struct TagEditor: View {
    let video: VideoItem
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var newName = ""
    @State private var showNew = false

    private var allTags: [String] {
        var s = Set(TagStore.suggestions)
        s.formUnion(TagStore.allKnownTags())
        s.formUnion(chosen)
        return Array(s).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allTags, id: \.self) { t in
                        Button {
                            if chosen.contains(t) { chosen.remove(t) } else { chosen.insert(t) }
                        } label: {
                            HStack {
                                Text(t).font(.body)
                                Spacer()
                                Image(systemName: chosen.contains(t) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(chosen.contains(t) ? Color.accentColor : Color.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("点选多个标签 · 右上保存")
                }
                Section {
                    Button {
                        showNew = true
                    } label: {
                        Label("新建标签…", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("新标签会当场勾上，保存后出现在库页顶部筛选里")
                }
            }
            .navigationTitle("标签 · \(String(video.title.prefix(12)))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        TagStore.setTags(video.id, Array(chosen))
                        dismiss()
                    }
                    .bold()
                }
            }
            .alert("新建标签", isPresented: $showNew) {
                TextField("名字（12 字内）", text: $newName)
                Button("取消", role: .cancel) { newName = "" }
                Button("添加") {
                    var t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count > 12 { t = String(t.prefix(12)) }
                    if !t.isEmpty { chosen.insert(t) }
                    newName = ""
                }
            } message: {
                Text("起个名，比如「王小刀」「待看」「精华」")
            }
            .onAppear { chosen = Set(TagStore.tags(video.id)) }
        }
    }
}
