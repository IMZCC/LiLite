import SwiftUI

struct AboutPanel: View {
  @EnvironmentObject private var accounts: AccountContext
  @State private var taps = 0
  @State private var input = false
  @State private var link = ""
  @State private var route: IncomingRoute?
  @State private var confirmCache = false
  @State private var confirmLogs = false
  @State private var bytes = 0
  @State private var message: String?
  @State private var reset: AboutReset.Scope?
  @State private var resetting = false
  private let source = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
  private var version: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
      + "+" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
  }
  var body: some View {
    Form {
      Section {
        Button {
          taps += 1
          if taps == 5 {
            taps = 0
            input = true
          }
        } label: {
          VStack(spacing: 10) {
            if let icon = UIImage(named: "AppIcon") {
              Image(uiImage: icon).resizable().scaledToFit().frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            }
            Text("轻哩 LiLite").font(.title2.bold()).foregroundStyle(.primary)
            Text("版本 " + version).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
          }
          .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).listRowBackground(Color.clear)
        .accessibilityLabel("轻哩 LiLite").accessibilityAction(named: "打开链接") { input = true }
      }
      Section {
        Button { input = true } label: {
          Label("打开链接", systemImage: "link").labelStyle(SettingsIconLabelStyle(color: .blue))
        }
        NavigationLink {
          VersionPanel()
        } label: {
          HStack {
            Label("版本与更新", systemImage: "arrow.down.app.fill").labelStyle(SettingsIconLabelStyle(color: .blue))
            Spacer()
            Text(version).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        .contextMenu { Button("复制版本号") { UIPasteboard.general.string = version } }
        Link(destination: UpstreamRelease.lilite) {
          Label("项目源码", systemImage: "chevron.left.forwardslash.chevron.right").labelStyle(SettingsIconLabelStyle(color: .gray))
        }
        Link(destination: UpstreamRelease.lilite.appendingPathComponent("issues")) {
          Label("问题反馈", systemImage: "exclamationmark.bubble.fill").labelStyle(SettingsIconLabelStyle(color: .orange))
        }
        NavigationLink { OpenSourceNotices() } label: {
          Label("开源许可", systemImage: "doc.text.fill").labelStyle(SettingsIconLabelStyle(color: .gray))
        }
      }
      Section("构建信息") {
        if let date = Bundle.main.object(forInfoDictionaryKey: "PiliNativeBuildDate") as? String,
          let d = ISO8601DateFormatter().date(from: date)
        {
          LabeledContent("构建时间", value: d.formatted())
        }
        if let rev = Bundle.main.object(forInfoDictionaryKey: "PiliNativeSourceRevision") as? String
        {
          LabeledContent("原生源码修订", value: String(rev.prefix(12))).monospacedDigit().contextMenu {
            Button("复制完整修订") { UIPasteboard.general.string = rev }
          }
        }
        Link(destination: UpstreamRelease.project.appendingPathComponent("commit/" + source)) {
          LabeledContent("原版源码修订", value: String(source.prefix(12))).foregroundStyle(.primary)
        }
        .contextMenu { Button("复制完整修订") { UIPasteboard.general.string = source } }
      }
      Section("诊断") {
        NavigationLink { DiagnosticView() } label: {
          Label("错误日志", systemImage: "waveform.path.ecg").labelStyle(SettingsIconLabelStyle(color: .gray))
        }.contextMenu {
          Button("清空日志", role: .destructive) { confirmLogs = true }
        }
        Button {
          confirmCache = true
        } label: {
          HStack {
            Label("清除图片及网络缓存", systemImage: "trash.fill").labelStyle(SettingsIconLabelStyle(color: .red))
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
              .foregroundStyle(.secondary).monospacedDigit()
              .contentTransition(.numericText())
          }
        }
      }
      Section {
        NavigationLink { AboutTransfer(kind: .accounts) } label: {
          Label("登录信息导入与导出", systemImage: "person.badge.key.fill").labelStyle(SettingsIconLabelStyle(color: .blue))
        }
        NavigationLink { AboutTransfer(kind: .settings) } label: {
          Label("设置导入与导出", systemImage: "gearshape.2.fill").labelStyle(SettingsIconLabelStyle(color: .gray))
        }
        NavigationLink { DataPackPanel() } label: {
          Label("导入与导出所有数据", systemImage: "externaldrive.fill").labelStyle(SettingsIconLabelStyle(color: .gray))
        }
      } header: {
        Text("数据管理")
      }
      Section {
        Button("重置可导出的设置", role: .destructive) { reset = .preferences }
        Button("重置本机数据与登录信息", role: .destructive) { reset = .all }
      } footer: {
        Text("重置本机数据会清除账号、设置、记录和草稿，已下载的视频会保留。")
      }
      if resetting {
        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
      }
      if let message {
        Text(message).font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle("关于").disabled(resetting).task { await refresh() }
      .alert("打开链接", isPresented: $input) {
        TextField("链接、BV 号或 AV 号", text: $link).textInputAutocapitalization(.never)
        Button("打开") {
          let s = link
          link = ""
          if let candidate = SharedResolver.candidate(s) {
            Task {
              do { route = .init(link: try await candidate.resolve()) } catch {
                message = error.localizedDescription
              }
            }
          } else {
            message = "未识别此链接"
          }
        }
        Button("取消", role: .cancel) {}
      }.piliSheet(item: $route) { r in
        PiliNavigationStack {
          LinkDestination(item: r.link).toolbar { Button("完成") { route = nil } }
        }
      }
      .confirmationDialog("清空错误日志？", isPresented: $confirmLogs) {
        Button("清空", role: .destructive) {
          Task {
            do {
              try await DiagnosticJournal.shared.clear()
              message = "已清空日志"
            } catch { message = error.localizedDescription }
          }
        }
      }
      .confirmationDialog("清除图片及网络缓存？", isPresented: $confirmCache) {
        Button("清除", role: .destructive) {
          Task {
            await ArtworkStore.shared.clear()
            URLCache.shared.removeAllCachedResponses()
            await refresh()
            message = "已清除缓存"
          }
        }
      }
      .confirmationDialog(
        "确认重置？", isPresented: Binding(get: { reset != nil }, set: { if !$0 { reset = nil } }),
        presenting: reset
      ) { scope in
        Button("重置", role: .destructive) {
          Task { @MainActor in
            guard !resetting else { return }
            resetting = true
            defer { resetting = false }
            do {
              try await AboutReset.apply(scope, accounts: accounts)
              message = "已重置"
            } catch { message = error.localizedDescription }
          }
        }
      } message: { scope in
        Text(scope == .all ? "将清除本机账号、设置、记录和草稿。已下载的视频会保留" : "将重置可导出的设置，保留账号和使用记录")
      }
  }
  @MainActor private func refresh() async {
    let u = await ArtworkStore.shared.usage()
    bytes =
      u.disk + u.memory + URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
  }
}
