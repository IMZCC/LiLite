import SwiftUI
import UniformTypeIdentifiers

struct PictureLocationSettings: View {
  @State private var chosen: LocalFolderChoice?
  @State private var pick = false
  @State private var issue: String?
  var body: some View {
    Form {
      Section {
        LabeledContent {
          Text(chosen?.name ?? "系统照片")
        } label: {
          SettingsRowLabel(title: "当前位置", symbol: chosen == nil ? "photo.on.rectangle" : "folder", color: .blue)
        }
        Button("选择文件夹") { pick = true }
        if chosen != nil {
          Button("使用系统照片") {
            Task {
              do {
                try await FolderGrants.shared.reset(.pictures)
                chosen = nil
              } catch { issue = error.localizedDescription }
            }
          }
        }
      } header: {
        Text("保存原图和实况")
      } footer: {
        if let issue { Text(issue).foregroundStyle(.red) }
        else { Text("选择文件夹后，原图和实况照片会以文件形式保存") }
      }
    }.navigationTitle("图片保存位置").navigationBarTitleDisplayMode(.inline)
      .task {
        do { chosen = try await FolderGrants.shared.current(.pictures) } catch {
          issue = error.localizedDescription
        }
      }
      .fileImporter(isPresented: $pick, allowedContentTypes: [.folder]) { result in
        switch result {
        case .success(let url):
          Task {
            do {
              chosen = try await FolderGrants.shared.select(url, for: .pictures)
              issue = nil
            } catch { issue = error.localizedDescription }
          }
        case .failure(let error):
          if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
        }
      }
  }
}
struct OfflineLocationPanel: View {
  @ObservedObject private var downloads = Downloads.shared
  @EnvironmentObject private var accounts: AccountContext
  private var owner: String { accounts.state.owner(.role(.video)) ?? "" }
  private var rows: [OfflineVideo] { downloads.list.filter { $0.visible(to: owner) } }
  @State private var chosen: LocalFolderChoice?
  @State private var locations: [LocalFolderChoice] = []
  @State private var pick = false
  @State private var confirmMove = false
  @State private var issue: String?
  @State private var bytes: [OfflinePlace: Int64] = [:]
  @State private var unavailable = Set<OfflinePlace>()
  @State private var measuring = false
  @State private var refresh = 0
  private func name(_ place: OfflinePlace) -> String {
    switch place {
    case .app: return "应用内"
    case .folder(let id): return locations.first { $0.id == id }?.name ?? "所选文件夹"
    }
  }
  private var wanted: OfflinePlace { chosen.map { .folder($0.id) } ?? .app }
  var body: some View {
    Form {
      Section {
        LabeledContent {
          Text(name(wanted))
        } label: {
          SettingsRowLabel(title: "当前位置", symbol: chosen == nil ? "iphone" : "folder", color: .blue)
        }
        Button("选择或重新授权文件夹") { pick = true }
        if chosen != nil {
          Button("使用应用内存储") {
            Task {
              do {
                try await FolderGrants.shared.reset(.cache)
                chosen = nil
                refresh += 1
              } catch { issue = error.localizedDescription }
            }
          }
        }
      } header: {
        Text("新缓存保存到")
      } footer: {
        if let issue { Text(issue).foregroundStyle(.red) }
      }
      Section {
        NavigationLink { DeferredPage { LegacyCacheImportView() } } label: {
          SettingsRowLabel(title: "恢复原版缓存清单", symbol: "arrow.triangle.2.circlepath", color: .green)
        }
      }
      Section {
        ForEach(
          Array(Set(rows.map(\.location)).union(bytes.keys).union(unavailable)).sorted {
            name($0) < name($1)
          }, id: \.self
        ) { place in
          let n = rows.filter { $0.location == place }.count
          LabeledContent {
            if unavailable.contains(place) {
              Text("\(n) 项 · 暂时不可访问").foregroundStyle(.orange)
            } else {
              Text(
                "\(n) 项 · "
                  + (bytes[place].map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                  } ?? "计算中")).monospacedDigit()
            }
          } label: {
            Label(name(place), systemImage: place == .app ? "iphone" : "folder")
          }
        }
        Button("移动已完成缓存到当前位置") { confirmMove = true }
          .disabled(
            !rows.contains {
              $0.phase == .saved && ($0.location != wanted || $0.moveTo != nil || $0.retire != nil)
            })
        Button("重试未完成的移动") {
          Task {
            await downloads.retryStorage()
            refresh += 1
          }
        }
        .disabled(!rows.contains { $0.moveTo != nil || $0.retire != nil })
        if !downloads.moving.isEmpty { ProgressView("正在整理缓存") }
        ForEach(rows.filter { $0.storageIssue != nil }) { v in
          VStack(alignment: .leading) {
            Text(v.title).font(.subheadline)
            Text(v.storageIssue ?? "").font(.caption).foregroundStyle(.secondary)
          }
        }
      } header: {
        HStack {
          Text("已有缓存")
          Spacer()
          if measuring { ProgressView().controlSize(.small) }
        }
      }
    }.navigationTitle("缓存位置").navigationBarTitleDisplayMode(.inline)
      .confirmationDialog("移动到「\(name(wanted))」？", isPresented: $confirmMove) {
        Button("移动已完成的缓存") {
          let target = wanted
          Task {
            await downloads.moveSaved(to: target)
            refresh += 1
          }
        }
      } message: {
        Text("移动成功后会释放原位置的媒体文件")
      }
      .fileImporter(isPresented: $pick, allowedContentTypes: [.folder]) { result in
        switch result {
        case .success(let url):
          Task {
            do {
              chosen = try await FolderGrants.shared.select(url, for: .cache)
              refresh += 1
              issue = nil
            } catch { issue = error.localizedDescription }
          }
        case .failure(let error):
          if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
        }
      }
      .task(id: "\(owner):\(refresh):\(downloads.moving.count):\(rows.count)") {
        do {
          chosen = try await FolderGrants.shared.current(.cache)
          locations = try await FolderGrants.shared.choices()
        } catch { issue = error.localizedDescription }
        measuring = true
        let metrics = await downloads.storageUsage()
        if !Task.isCancelled {
          bytes = metrics.0
          unavailable = metrics.1
          measuring = false
        }
      }
  }
}
struct OfflineLocationStatus: View {
  let video: OfflineVideo
  var body: some View {
    if let error = video.storageIssue {
      Text(error).font(.caption).foregroundStyle(.secondary)
    } else if video.moveTo != nil && video.phase == .saved {
      Label("等待移动", systemImage: "folder.badge.clock").font(.caption)
    } else if case .folder = video.location {
      Label("保存在文件夹", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
    }
  }
}
