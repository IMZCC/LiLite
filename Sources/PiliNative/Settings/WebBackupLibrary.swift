import SwiftUI

struct DAVLibrary: View {
  let connection: DAVConnection
  @State private var files: [DAVEntry] = []
  @State private var busy = false
  @State private var loaded = false
  @State private var message: String?
  @State private var pendingDelete: DAVEntry?
  var body: some View {
    List {
      if !connection.target.folders.isEmpty {
        Section {
          Button {
            Task {
              await perform {
                let data = try NativePrefs.current().archive()
                try await connection.withStore { try await $0.snapshot(data, encrypted: false) }
                try await refresh()
                message = "已保存设置备份"
              }
            }
          } label: {
            SettingsRowLabel(title: "保存一份当前设置", symbol: "icloud.and.arrow.up", color: .blue)
          }
          NavigationLink {
            DataPackPanel(upload: { bytes in
              guard DataPackCipher.sealed(bytes) else { throw ServiceError("请使用加密数据包") }
              try await connection.withStore { try await $0.snapshot(bytes, encrypted: true) }
            })
          } label: {
            SettingsRowLabel(title: "上传加密数据包", symbol: "lock.doc", color: .indigo)
          }
        }
      }
      Section {
        ForEach(files) { f in
          Group {
            NavigationLink {
              DataPackPanel(remoteSource: {
                try await connection.withStore { try await $0.read(f) }
              })
            } label: {
              row(f)
            }
          }.swipeActions {
            if f.deletionCondition != nil { Button("删除", role: .destructive) { pendingDelete = f } }
          }
          .contextMenu {
            if f.deletionCondition != nil {
              Button("删除备份", role: .destructive) { pendingDelete = f }
            }
          }
        }
        if loaded && files.isEmpty { Text("没有备份文件").foregroundStyle(.secondary) }
      } header: {
        HStack {
          Text("备份文件")
          Spacer()
          if busy { ProgressView().controlSize(.small) }
        }
      } footer: {
        if let message { Text(message) }
      }
    }
    .navigationTitle("远程备份").navigationBarTitleDisplayMode(.inline).disabled(busy)
    .refreshable { await perform { try await refresh() } }
    .toolbar {
      Button { Task { await perform { try await refresh() } } } label: {
        Label("刷新列表", systemImage: "arrow.clockwise")
      }
    }
    .task { await perform { try await refresh() } }
      .confirmationDialog(
        "删除远程备份？",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { f in
        Button("删除", role: .destructive) {
          Task {
            await perform {
              try await connection.withStore { try await $0.delete(f) }
              try await refresh()
              message = "已删除备份"
            }
          }
        }
      } message: {
        Text($0.name)
      }
  }
  private func row(_ f: DAVEntry) -> some View {
    HStack(spacing: 12) {
      Image(systemName: f.name.hasSuffix(".json") ? "doc.text" : "shippingbox")
        .font(.title3).foregroundStyle(.tint).frame(width: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(f.name).lineLimit(2)
        if let size = f.size {
          Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
  @MainActor private func refresh() async throws {
    files = try await connection.withStore { try await $0.contents() }
    loaded = true
  }
  @MainActor private func perform(_ work: () async throws -> Void) async {
    guard !busy else { return }
    busy = true
    message = nil
    defer { busy = false }
    do { try await work() } catch { message = error.localizedDescription }
  }
}
