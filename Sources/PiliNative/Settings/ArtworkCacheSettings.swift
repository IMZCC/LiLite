import SwiftUI

struct ArtworkCacheSettings: View {
  @AppStorage(ArtworkStore.key) private var limit = ArtworkStore.standard
  @State private var draft = ""
  @State private var usage = 0
  @State private var memory = 0
  @State private var confirm = false
  private var proposed: Int? {
    let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: ",", with: ".")
    guard let mb = Double(normalized), mb.isFinite, mb >= 0, mb <= 999_999 else { return nil }
    return Int((mb * Double(ArtworkStore.mib)).rounded())
  }
  private func refresh() async {
    let result = await ArtworkStore.shared.usage()
    usage = result.disk
    memory = result.memory
  }
  private func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
  }
  var body: some View {
    Form {
      Section("空间") {
        if limit > 0 {
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
              Text(size(usage)).font(.title2.weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
              Text("/ " + size(limit)).font(.subheadline).foregroundStyle(.secondary)
              Spacer()
            }
            ProgressView(value: min(1, Double(usage) / Double(max(1, limit))))
              .tint(Double(usage) / Double(max(1, limit)) > 0.9 ? .orange : .accentColor)
          }
          .padding(.vertical, 6)
          .animation(.snappy, value: usage)
        }
        LabeledContent("磁盘缓存", value: size(usage)).settingAnchor("ArtworkCacheSettings/磁盘缓存")
        LabeledContent("内存缓存", value: size(memory)).settingAnchor("ArtworkCacheSettings/内存缓存")
        Button("清理图片缓存", role: .destructive) { confirm = true }.settingAnchor("ArtworkCacheSettings/清理图片缓存")
      }.settingAnchor("ArtworkCacheSettings/空间")
      Section {
        LabeledContent("上限（MB）") {
          TextField("1024", text: $draft).multilineTextAlignment(.trailing).keyboardType(
            .decimalPad)
        }.settingAnchor("ArtworkCacheSettings/上限（MB）")
        Button("保存上限") {
          if let proposed {
            limit = proposed
            Task { await refresh() }
          }
        }.settingAnchor("ArtworkCacheSettings/保存上限").disabled(proposed == nil || proposed == limit)
      } footer: {
        Text("设为 0 可关闭图片缓存，已下载的视频单独保留")
      }
    }.navigationTitle("图片缓存").task {
      draft =
        limit.isMultiple(of: ArtworkStore.mib)
        ? String(limit / ArtworkStore.mib) : String(Double(limit) / Double(ArtworkStore.mib))
      await refresh()
    }.confirmationDialog("清理图片缓存？", isPresented: $confirm) {
      Button("清理", role: .destructive) {
        Task {
          await ArtworkStore.shared.clear()
          await refresh()
        }
      }
    }
  }
}
