import Foundation
import MetricKit
import SwiftUI

struct LocalReport: Codable, Identifiable {
  let id: UUID, date: Date, category: String, detail: String, version: String, system: String
  var text: String { "\(date.formatted()) · \(category)\n\(detail)\n\(version) · iOS \(system)" }
}
actor DiagnosticJournal {
  static let shared = DiagnosticJournal()
  static let key = "diagnostic.enabled"
  private var reports: [LocalReport]?
  private var pendingWrite: Task<Void, Never>?
  private var dirty = false
  private var lastPlayback = -Double.infinity, suppressedPlayback = 0
  private var path: URL {
    get throws {
      let dir = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      return dir.appendingPathComponent("diagnostics.json")
    }
  }
  func read() throws -> [LocalReport] {
    if let reports { return reports }
    let url = try path
    guard FileManager.default.fileExists(atPath: url.path) else {
      reports = []
      return []
    }
    let data = try Data(contentsOf: url)
    let values = Array(try JSONDecoder().decode([LocalReport].self, from: data).prefix(300))
    reports = values
    return values
  }
  private func put(_ values: [LocalReport]) throws {
    let url = try path
    let data = try JSONEncoder().encode(values)
    try data.write(
      to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    reports = values
  }
  func add(_ category: String, _ detail: String, date: Date = Date()) {
    guard UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true else { return }
    var detail = detail
    if category == "播放同步" {
      let now = ProcessInfo.processInfo.systemUptime
      guard now - lastPlayback >= 10 else { suppressedPlayback += 1; return }
      lastPlayback = now
      if suppressedPlayback > 0 { detail += "\n合并了 \(suppressedPlayback) 条重复同步事件" }
      suppressedPlayback = 0
    }
    do {
      let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
      let os = ProcessInfo.processInfo.operatingSystemVersion
      let entry = LocalReport(
        id: UUID(), date: date, category: category, detail: String(detail.prefix(4000)),
        version: version, system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
      var list = try read()
      if let last = list.first, last.category == category, last.detail == entry.detail,
        abs(last.date.timeIntervalSince(date)) < 2
      {
        return
      }
      list.insert(entry, at: 0)
      reports = Array(list.prefix(300))
      dirty = true
      // Coalesce a burst into one write; continuous events cannot postpone it indefinitely.
      if pendingWrite == nil {
        pendingWrite = Task {
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          try? flush()
        }
      }
    } catch {}
  }
  func flush() throws {
    pendingWrite?.cancel(); pendingWrite = nil
    guard dirty, let reports else { return }
    try put(reports)
    dirty = false
  }
  func clear() throws {
    pendingWrite?.cancel(); pendingWrite = nil
    try put([])
    dirty = false; lastPlayback = -Double.infinity; suppressedPlayback = 0
  }
  static func service(_ path: String) -> String {
    let p = path.lowercased()
    if p.contains("dm/") || p.contains("danmaku") { return "弹幕" }
    if p.contains("im/") || p.contains("msg") || p.contains("session") { return "消息" }
    if p.contains("history") || p.contains("fav") { return "个人片库" }
    if p.contains("player") || p.contains("playurl") { return "媒体播放" }
    if p.contains("relation") || p.contains("space") { return "创作者" }
    if p.contains("reply") || p.contains("dynamic") { return "社区" }
    if p.contains("member") || p.contains("passport") { return "账号" }
    return "内容请求"
  }
  static func network(_ path: String, _ kind: String, _ code: Int) {
    let service = service(path)
    Task { await shared.add(service, "\(kind) · \(code)") }
  }
}
final class NativeMetricSubscriber: NSObject, MXMetricManagerSubscriber {
  static let shared = NativeMetricSubscriber()
  @MainActor private static var started = false
  @MainActor static func start() {
    guard !started else { return }
    started = true
    MXMetricManager.shared.add(shared)
  }
  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for p in payloads {
      let date = p.timeStampEnd
      for d in p.crashDiagnostics ?? [] {
        let trace = Self.trace(d.callStackTree)
        let text = [
          "信号 " + (d.signal?.stringValue ?? "—"), "异常类型 " + (d.exceptionType?.stringValue ?? "—"),
          "异常代码 " + (d.exceptionCode?.stringValue ?? "—"), trace,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        Task { await DiagnosticJournal.shared.add("应用崩溃", text, date: date) }
      }
      for d in p.hangDiagnostics ?? [] {
        let time = d.hangDuration.converted(to: .seconds).value
        let text = String(format: "停顿 %.2f 秒", time) + "\n" + Self.trace(d.callStackTree)
        Task { await DiagnosticJournal.shared.add("应用卡顿", text, date: date) }
      }
      for d in p.cpuExceptionDiagnostics ?? [] {
        let text = Self.trace(d.callStackTree)
        Task { await DiagnosticJournal.shared.add("CPU 占用", text, date: date) }
      }
      for d in p.diskWriteExceptionDiagnostics ?? [] {
        let text = Self.trace(d.callStackTree)
        Task { await DiagnosticJournal.shared.add("磁盘写入", text, date: date) }
      }
    }
  }
  private static func trace(_ tree: MXCallStackTree) -> String {
    guard
      let data = (try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()))
        as? [String: Any],
      let stacks = data["callStacks"] as? [[String: Any]]
    else { return "" }
    var frames: [String] = []
    func visit(_ list: [[String: Any]], _ depth: Int) {
      guard depth < 28 else { return }
      for f in list {
        guard frames.count < 20 else { return }
        if let name = f["binaryName"] as? String, name.contains("PiliNative"),
          let offset = f["offsetIntoBinaryTextSegment"] as? NSNumber
        {
          frames.append("PiliNative +0x" + String(offset.uint64Value, radix: 16))
        }
        if let sub = f["subFrames"] as? [[String: Any]] { visit(sub, depth + 1) }
      }
    }
    for stack in stacks { visit(stack["callStackRootFrames"] as? [[String: Any]] ?? [], 0) }
    return frames.joined(separator: "\n")
  }
}
struct DiagnosticView: View {
  @AppStorage(DiagnosticJournal.key) private var enabled = true
  @State private var reports: [LocalReport] = []
  @State private var clear = false
  @State private var issue: String?
  @State private var filter = ""
  private var shown: [LocalReport] {
    filter.isEmpty ? reports : reports.filter { $0.text.localizedCaseInsensitiveContains(filter) }
  }
  var body: some View {
    List {
      Section {
        Toggle("记录诊断日志", isOn: $enabled)
        DisclosureGroup("设备与应用") {
          LabeledContent("系统",value:UIDevice.current.systemName+" "+UIDevice.current.systemVersion)
          LabeledContent("设备",value:UIDevice.current.localizedModel)
          LabeledContent("版本",value:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—")
          if let commit=Bundle.main.object(forInfoDictionaryKey:"PiliNativeSourceRevision") as? String {Text(commit).font(.footnote.monospaced()).textSelection(.enabled)}
        }
        Link("错误反馈",destination:UpstreamRelease.lilite.appendingPathComponent("issues"))
      } footer: {
        Text("日志只保存在本机，反馈问题时可以复制附上。")
      }
      if let issue {
        PageFailure(message: issue) { Task { await reload() } }
      }
      Section {
        ForEach(shown) { r in
          DisclosureGroup {
            Text(r.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            Button("复制这条记录") { UIPasteboard.general.string = r.text }
          } label: {
            HStack(spacing: 10) {
              Text(r.category).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
              Text(r.detail.split(separator: "\n").first.map(String.init) ?? "")
                .font(.footnote).lineLimit(1).foregroundStyle(.primary)
              Spacer(minLength: 4)
              Text(r.date, format: .dateTime.month().day().hour().minute()).font(.caption2)
                .foregroundStyle(.secondary).monospacedDigit()
            }
          }
        }
      } header: {
        if !shown.isEmpty { Text("\(shown.count) 条记录") }
      }
      if shown.isEmpty && issue == nil {
        ContentUnavailableView(filter.isEmpty ? "暂无日志" : "没有匹配的记录", systemImage: "waveform.path.ecg")
          .listRowBackground(Color.clear)
      }
    }
    .animation(.easeOut(duration: 0.2), value: shown.map(\.id)).navigationTitle("日志").searchable(text: $filter).piliRefreshable { await reload() }.task {
      await reload()
    }
    .toolbar {
      Menu {
        Button("复制全部") {
          UIPasteboard.general.string = reports.map(\.text).joined(separator: "\n\n")
        }.disabled(reports.isEmpty)
        Button("记录测试事件") {
          Task {
            await DiagnosticJournal.shared.add("手动诊断", "用户请求了一条测试记录")
            await reload()
          }
        }.disabled(!enabled)
        Button("清空日志", role: .destructive) { clear = true }.disabled(reports.isEmpty)
      } label: {
        Image(systemName: "ellipsis.circle").accessibilityLabel("日志操作")
      }
    }
    .confirmationDialog("清空本机日志？", isPresented: $clear) {
      Button("清空", role: .destructive) {
        Task {
          do {
            try await DiagnosticJournal.shared.clear()
            await reload()
          } catch { issue = error.localizedDescription }
        }
      }
    }
  }
  @MainActor private func reload() async {
    do {
      reports = try await DiagnosticJournal.shared.read()
      issue = nil
    } catch { issue = error.localizedDescription }
  }
}
