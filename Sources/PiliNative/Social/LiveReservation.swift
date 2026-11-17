import SwiftUI

struct LiveReservation: Identifiable {
  let id: Int64, title: String, start: Date, subtype: Int
}
extension BiliAPI {
  func reservation(_ id: Int64, uid: String, subtype: Int) async throws -> LiveReservation {
    struct Info: Decodable {
      let id: Int64, title: String, live_plan_start_time: Int64, sub_type: Int?
    }
    let r = try await read(
      "/x/new-reserve/up/reserve/info",
      ["from": "1", "id": String(id), "web_location": "333.1365"], expectedAccount: uid,
      as: Info.self)
    guard r.id == id else { throw ServiceError("预约编号不匹配") }
    return .init(
      id: r.id, title: r.title, start: Date(timeIntervalSince1970: Double(r.live_plan_start_time)),
      subtype: r.sub_type ?? subtype)
  }
  func saveReservation(_ id: Int64?, uid: String, title: String, start: Date, subtype: Int)
    async throws -> LiveReservation
  {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let interval = start.timeIntervalSinceNow
    guard !name.isEmpty, name.count <= 14, [0, 1].contains(subtype), interval >= 300,
      interval <= 90 * 86400
    else { throw ServiceError("请输入有效的预约标题和时间") }
    var f = [
      "type": "2", "sub_type": String(subtype), "from": "1", "title": name,
      "live_plan_start_time": String(Int64(start.timeIntervalSince1970)),
    ]
    if let id { f["id"] = String(id) }
    let data = try await submitResponse(
      "/x/new-reserve/up/reserve/" + (id == nil ? "create" : "update"), f, expectedAccount: uid)
    struct Envelope: Decodable {
      struct Info: Decodable { let sid: Int64? }
      let data: Info?
    }
    let receipt = try JSONDecoder().decode(Envelope.self, from: data).data?.sid
    if receipt == nil, let id {
      let confirmed = try await reservation(id, uid: uid, subtype: subtype)
      guard confirmed.title == name, abs(confirmed.start.timeIntervalSince(start)) < 1,
        confirmed.subtype == subtype
      else { throw ServiceError("预约已提交，请重新读取以确认状态") }
      return confirmed
    }
    guard let sid = receipt, sid > 0 else { throw ServiceError("预约服务没有返回编号") }
    if let id, sid != id { throw ServiceError("预约服务返回了不同的编号") }
    return .init(id: sid, title: name, start: start, subtype: subtype)
  }
}
struct ReservationEditor: View {
  let uid: String, original: LiveReservation?, select: (LiveReservation) -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var title = ""
  @State private var subtype = 0
  @State private var date: Date =
    Calendar.current.date(
      bySettingHour: 20, minute: 0, second: 0,
      of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    ?? Date().addingTimeInterval(86400)
  @State private var busy = false
  @State private var ready = false
  @State private var issue: String?
  @State private var attempt = 0
  var body: some View {
    Form {
      Picker("类型", selection: $subtype) {
        Text("公开直播").tag(0)
        Text("大航海直播").tag(1)
      }
      TextField("预约标题", text: $title)
      Text("\(title.count)/14").font(.caption).foregroundStyle(.secondary)
      DatePicker(
        "开播时间", selection: $date, in: Date()...Date().addingTimeInterval(90 * 86400),
        displayedComponents: [.date, .hourAndMinute])
      if busy { ProgressView() }
      Button(original == nil ? "创建并添加预约" : "保存预约") { Task { await save() } }
        .disabled(
          busy || !ready || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || title.count > 14 || date.timeIntervalSinceNow < 300)
      if let issue {
        Text(issue)
        if !ready { Button("重试") { attempt += 1 } }
      }
    }.navigationTitle("直播预约").onChange(of: accounts.state.active) { _, active in
      if active != uid { dismiss() }
    }.task(id: attempt) {
      guard let original else {
        ready = true
        return
      }
      do {
        let r = try await BiliAPI.shared.reservation(
          original.id, uid: uid, subtype: original.subtype)
        try Task.checkCancellation()
        title = r.title
        subtype = r.subtype
        date = r.start
        ready = true
        issue = nil
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
  @MainActor private func save() async {
    guard !busy, accounts.state.active == uid else { return }
    busy = true
    defer { busy = false }
    do {
      let r = try await BiliAPI.shared.saveReservation(
        original?.id, uid: uid, title: title, start: date, subtype: subtype)
      guard accounts.state.active == uid else { return }
      select(r)
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
